const admin = require('firebase-admin');
const stripe = require('stripe');
const { onCall, HttpsError, onRequest } = require('firebase-functions/v2/https');
const { onDocumentDeleted } = require('firebase-functions/v2/firestore');
const { onUserDeleted } = require('firebase-functions/v2/identity');

admin.initializeApp();

const db = admin.firestore();

function isAuthUserNotFound(error) {
  return error?.code === 'auth/user-not-found';
}

function isFirestoreNotFound(error) {
  return error?.code === 5;
}

async function safeDeleteDocument(ref) {
  try {
    await ref.delete();
  } catch (error) {
    if (!isFirestoreNotFound(error)) {
      throw error;
    }
  }
}

async function safeDeleteAuthUser(uid) {
  try {
    await admin.auth().deleteUser(uid);
  } catch (error) {
    if (!isAuthUserNotFound(error)) {
      throw error;
    }
  }
}

async function deleteCollectionByField(collectionName, fieldName, value) {
  const snapshot = await db
    .collection(collectionName)
    .where(fieldName, '==', value)
    .get();
  for (const doc of snapshot.docs) {
    await doc.ref.delete();
  }
}

async function cleanupUserBackendsByUid(
  uid,
  { deleteAuth = true, deleteUserDocument = false } = {},
) {
  if (deleteAuth) {
    await safeDeleteAuthUser(uid);
  }

  if (deleteUserDocument) {
    await safeDeleteDocument(db.collection('users').doc(uid));
  }

  await safeDeleteDocument(db.collection('therapist_profiles').doc(uid));

  const childSnapshot = await db
    .collection('child_profiles')
    .where('parentId', '==', uid)
    .get();
  const childIds = [];
  for (const childDoc of childSnapshot.docs) {
    childIds.push(childDoc.id);
    await childDoc.ref.delete();
  }

  for (const childId of childIds) {
    await safeDeleteDocument(db.collection('child_assignments').doc(childId));
    await safeDeleteDocument(db.collection('dashboard_snapshots').doc(childId));
    await deleteCollectionByField('mood_logs', 'childId', childId);
    await deleteCollectionByField('activity_progress', 'childId', childId);
  }

  const threadRefs = new Map();
  const parentThreads = await db
    .collection('therapist_threads')
    .where('parentId', '==', uid)
    .get();
  for (const doc of parentThreads.docs) {
    threadRefs.set(doc.ref.path, doc.ref);
  }
  const therapistThreads = await db
    .collection('therapist_threads')
    .where('therapistId', '==', uid)
    .get();
  for (const doc of therapistThreads.docs) {
    threadRefs.set(doc.ref.path, doc.ref);
  }
  for (const ref of threadRefs.values()) {
    await db.recursiveDelete(ref);
  }

  const subscriptions = await db
    .collection('subscriptions')
    .where('userId', '==', uid)
    .get();
  for (const doc of subscriptions.docs) {
    await doc.ref.delete();
  }

  await deleteCollectionByField('feedback', 'userId', uid);
}

function getStripe() {
  const secretKey = process.env.PAYMENT_PROVIDER_SECRET_KEY;
  if (!secretKey) {
    throw new Error('Missing PAYMENT_PROVIDER_SECRET_KEY');
  }
  return stripe(secretKey);
}

async function getUserDoc(uid) {
  const snapshot = await db.collection('users').doc(uid).get();
  if (!snapshot.exists) {
    throw new HttpsError('not-found', 'User profile not found');
  }
  return snapshot;
}

async function getOrCreateCustomer(stripeClient, uid, email) {
  const userRef = db.collection('users').doc(uid);
  const userDoc = await userRef.get();
  const existingCustomerId = userDoc.data()?.stripeCustomerId;
  if (existingCustomerId) {
    return existingCustomerId;
  }

  const customer = await stripeClient.customers.create({
    email,
    metadata: { userId: uid },
  });
  await userRef.set({ stripeCustomerId: customer.id }, { merge: true });
  return customer.id;
}

exports.createStripeCheckoutSession = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentication required');
  }

  const { productId, successUrl, cancelUrl } = request.data || {};
  if (!productId || !successUrl || !cancelUrl) {
    throw new HttpsError('invalid-argument', 'Missing checkout parameters');
  }

  const stripeClient = getStripe();
  const productDoc = await db.collection('subscription_products').doc(productId).get();
  if (!productDoc.exists) {
    throw new HttpsError('not-found', 'Subscription product not found');
  }

  const product = productDoc.data();
  const priceId = product?.stripePriceId;
  if (!priceId) {
    throw new HttpsError('failed-precondition', 'Product missing stripePriceId');
  }

  const userDoc = await getUserDoc(request.auth.uid);
  const customerId = await getOrCreateCustomer(
    stripeClient,
    request.auth.uid,
    userDoc.data().email,
  );

  const session = await stripeClient.checkout.sessions.create({
    mode: 'subscription',
    customer: customerId,
    success_url: successUrl,
    cancel_url: cancelUrl,
    line_items: [{ price: priceId, quantity: 1 }],
    metadata: {
      userId: request.auth.uid,
      productId,
    },
  });

  return {
    url: session.url,
    sessionId: session.id,
  };
});

exports.cancelStripeSubscription = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentication required');
  }

  const { subscriptionId } = request.data || {};
  const subscriptionDoc = await db.collection('subscriptions').doc(subscriptionId).get();
  if (!subscriptionDoc.exists) {
    throw new HttpsError('not-found', 'Subscription not found');
  }

  const subscriptionData = subscriptionDoc.data();
  if (subscriptionData.userId !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'Cannot cancel another user subscription');
  }

  const stripeClient = getStripe();
  await stripeClient.subscriptions.update(subscriptionData.stripeSubscriptionId, {
    cancel_at_period_end: true,
  });

  await subscriptionDoc.ref.set({
    cancelAtPeriodEnd: true,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { status: 'cancel_scheduled' };
});

exports.reactivateStripeSubscription = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentication required');
  }

  const { subscriptionId } = request.data || {};
  const subscriptionDoc = await db.collection('subscriptions').doc(subscriptionId).get();
  if (!subscriptionDoc.exists) {
    throw new HttpsError('not-found', 'Subscription not found');
  }

  const subscriptionData = subscriptionDoc.data();
  if (subscriptionData.userId !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'Cannot reactivate another user subscription');
  }

  const stripeClient = getStripe();
  await stripeClient.subscriptions.update(subscriptionData.stripeSubscriptionId, {
    cancel_at_period_end: false,
  });

  await subscriptionDoc.ref.set({
    cancelAtPeriodEnd: false,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { status: 'reactivated' };
});

exports.stripeWebhook = onRequest(async (req, res) => {
  try {
    const stripeClient = getStripe();
    const signature = req.headers['stripe-signature'];
    const webhookSecret = process.env.PAYMENT_PROVIDER_WEBHOOK_SECRET;
    const event = stripeClient.webhooks.constructEvent(
      req.rawBody,
      signature,
      webhookSecret,
    );

    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      const userId = session.metadata?.userId;
      const productId = session.metadata?.productId;
      if (userId && productId) {
        await db.collection('subscriptions').doc(session.subscription).set({
          userId,
          productId,
          stripeCustomerId: session.customer,
          stripeSubscriptionId: session.subscription,
          status: 'active',
          cancelAtPeriodEnd: false,
          currentPeriodEnd: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        await db.collection('users').doc(userId).set({
          subscriptionTier: 'professional-support',
          entitlements: {
            professionalSupport: true,
            chatAccess: true,
          },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    if (
      event.type === 'customer.subscription.updated' ||
      event.type === 'customer.subscription.deleted'
    ) {
      const subscription = event.data.object;
      const subscriptionRef = db.collection('subscriptions').doc(subscription.id);
      const existing = await subscriptionRef.get();
      const userId = existing.data()?.userId;

      await subscriptionRef.set({
        status: subscription.status,
        cancelAtPeriodEnd: subscription.cancel_at_period_end,
        currentPeriodEnd: subscription.current_period_end
          ? admin.firestore.Timestamp.fromMillis(subscription.current_period_end * 1000)
          : null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      if (userId) {
        const active = subscription.status === 'active' || subscription.status === 'trialing';
        await db.collection('users').doc(userId).set({
          entitlements: {
            professionalSupport: active,
            chatAccess: active,
          },
          subscriptionTier: active ? 'professional-support' : 'free',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    res.status(200).send({ received: true });
  } catch (error) {
    console.error(error);
    res.status(400).send({ error: error.message });
  }
});

exports.cleanupDeletedUserDocument = onDocumentDeleted(
  'users/{uid}',
  async (event) => {
    const uid = event.params.uid;
    if (!uid) {
      return;
    }

    await cleanupUserBackendsByUid(uid, {
      deleteAuth: true,
      deleteUserDocument: false,
    });
  },
);

exports.cleanupDeletedAuthUser = onUserDeleted(async (event) => {
  const uid = event.data?.uid;
  if (!uid) {
    return;
  }

  // Primary path: remove users/{uid} and let cleanupDeletedUserDocument handle
  // the cascade. Fallback path: if users/{uid} does not exist, cleanup directly.
  const userRef = db.collection('users').doc(uid);
  const userSnapshot = await userRef.get();
  if (userSnapshot.exists) {
    await safeDeleteDocument(userRef);
    return;
  }

  await cleanupUserBackendsByUid(uid, {
    deleteAuth: false,
    deleteUserDocument: false,
  });
});

exports.checkAccountExistsByEmail = onCall(async (request) => {
  const email = (request.data?.email || '').toString().trim().toLowerCase();
  if (!email) {
    throw new HttpsError('invalid-argument', 'Email is required');
  }

  // Prefer Auth as source of truth, then fall back to profile presence.
  let existsInAuth = false;
  try {
    await admin.auth().getUserByEmail(email);
    existsInAuth = true;
  } catch (error) {
    if (!isAuthUserNotFound(error)) {
      throw new HttpsError('internal', 'Unable to verify account existence');
    }
  }

  const userDocSnapshot = await db
    .collection('users')
    .where('email', '==', email)
    .limit(1)
    .get();
  const existsInUsers = !userDocSnapshot.empty;

  return {
    exists: existsInAuth || existsInUsers,
  };
});
