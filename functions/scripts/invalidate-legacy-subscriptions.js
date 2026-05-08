const admin = require('firebase-admin');

const projectId =
  process.env.FIREBASE_PROJECT_ID ||
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT;

if (admin.apps.length === 0) {
  if (projectId) {
    admin.initializeApp({ projectId });
  } else {
    admin.initializeApp();
  }
}

const db = admin.firestore();

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const part = argv[i];
    if (!part.startsWith('--')) {
      continue;
    }
    const key = part.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = true;
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function normalizeValue(value) {
  if (value == null) {
    return '';
  }
  return value.toString().trim();
}

function isLegacySubscription(data) {
  const provider = normalizeValue(data.provider).toLowerCase();
  if (provider && provider !== 'payfast_pk') {
    return true;
  }
  if (!provider) {
    const hasStripeShape =
      normalizeValue(data.stripeCustomerId) ||
      normalizeValue(data.stripeSubscriptionId) ||
      normalizeValue(data.stripePriceId);
    if (hasStripeShape) {
      return true;
    }
  }
  const platform = normalizeValue(data.platform).toLowerCase();
  return platform === 'android_play';
}

async function updateUserEntitlements(userId) {
  const subscriptions = await db
    .collection('subscriptions')
    .where('userId', '==', userId)
    .get();

  const hasActivePayfast = subscriptions.docs.some((doc) => {
    const data = doc.data() || {};
    const provider = normalizeValue(data.provider).toLowerCase();
    const status = normalizeValue(data.status).toLowerCase();
    return (
      provider === 'payfast_pk' &&
      (status === 'active' || status === 'trialing')
    );
  });

  await db.collection('users').doc(userId).set(
    {
      subscriptionTier: hasActivePayfast ? 'professional-support' : 'free',
      entitlements: {
        professionalSupport: hasActivePayfast,
        chatAccess: hasActivePayfast,
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  if (!hasActivePayfast) {
    const threadSnapshot = await db
      .collection('therapist_threads')
      .where('parentId', '==', userId)
      .get();
    if (!threadSnapshot.empty) {
      const batch = db.batch();
      for (const doc of threadSnapshot.docs) {
        batch.set(
          doc.ref,
          {
            status: 'canceled',
            postCancelVisible: true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
      await batch.commit();
    }
  }

  return hasActivePayfast;
}

async function invalidateLegacySubscriptions({ dryRun }) {
  const snapshot = await db.collection('subscriptions').get();
  const legacyDocs = snapshot.docs.filter((doc) => isLegacySubscription(doc.data() || {}));

  const userIds = new Set();
  for (const doc of legacyDocs) {
    const userId = normalizeValue(doc.data()?.userId);
    if (userId) {
      userIds.add(userId);
    }
  }

  let updatedSubscriptions = 0;
  if (!dryRun) {
    for (const doc of legacyDocs) {
      await doc.ref.set(
        {
          status: 'expired',
          isActive: false,
          cancelAtPeriodEnd: true,
          cutoverInvalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      updatedSubscriptions += 1;
    }
  }

  let usersWithAccess = 0;
  if (!dryRun) {
    for (const userId of userIds) {
      const hasAccess = await updateUserEntitlements(userId);
      if (hasAccess) {
        usersWithAccess += 1;
      }
    }
  }

  return {
    dryRun,
    totalSubscriptionsScanned: snapshot.size,
    legacySubscriptionsMatched: legacyDocs.length,
    legacySubscriptionsUpdated: updatedSubscriptions,
    usersEvaluated: userIds.size,
    usersRetainingAccess: usersWithAccess,
    usersRevoked: userIds.size - usersWithAccess,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const dryRun = args['dry-run'] === true;
  const summary = await invalidateLegacySubscriptions({ dryRun });
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
