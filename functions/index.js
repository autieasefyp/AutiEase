const admin = require('firebase-admin');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
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
