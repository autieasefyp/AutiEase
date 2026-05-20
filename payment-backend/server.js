const express = require('express');
const cors = require('cors');
const crypto = require('crypto');
const admin = require('firebase-admin');

const app = express();

function isTruthy(value) {
  if (value == null) {
    return false;
  }
  const normalized = value.toString().trim().toLowerCase();
  return ['1', 'true', 'yes', 'on'].includes(normalized);
}

function normalizeValue(value) {
  if (value == null) {
    return '';
  }
  return value.toString().trim();
}

function normalizeBaseUrl(url) {
  const value = normalizeValue(url);
  if (!value) {
    return '';
  }
  return value.endsWith('/') ? value.slice(0, -1) : value;
}

function parseAllowedOrigins() {
  const raw = normalizeValue(process.env.ALLOWED_ORIGINS);
  if (!raw) {
    return [];
  }
  return raw
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function initFirebaseAdmin() {
  if (admin.apps.length > 0) {
    return;
  }

  const projectId =
    process.env.FIREBASE_PROJECT_ID ||
    process.env.GCLOUD_PROJECT ||
    process.env.GOOGLE_CLOUD_PROJECT;

  const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (serviceAccountJson) {
    const serviceAccount = JSON.parse(serviceAccountJson);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId: projectId || serviceAccount.project_id,
    });
    return;
  }

  if (projectId) {
    admin.initializeApp({ projectId });
    return;
  }

  admin.initializeApp();
}

function jsonError(res, status, message) {
  res.status(status).json({ error: message });
}

function getBearerToken(req) {
  const authHeader = req.header('authorization') || req.header('Authorization');
  if (!authHeader) {
    return null;
  }
  const [scheme, token] = authHeader.split(' ');
  if (!scheme || !token || scheme.toLowerCase() !== 'bearer') {
    return null;
  }
  return token.trim();
}

async function requireAuth(req, res, next) {
  try {
    const token = getBearerToken(req);
    if (!token) {
      return jsonError(res, 401, 'Missing bearer token');
    }
    const decoded = await admin.auth().verifyIdToken(token);
    req.user = decoded;
    return next();
  } catch (error) {
    const details = error?.message || error?.code || 'Unknown auth error';
    console.error('Auth verification failed:', details);
    if (process.env.NODE_ENV !== 'production') {
      return jsonError(res, 401, `Unauthorized: ${details}`);
    }
    return jsonError(res, 401, 'Unauthorized');
  }
}

function resolveCheckoutBaseUrl(req) {
  const explicit = normalizeBaseUrl(process.env.PAYMENT_REDIRECT_BASE_URL || process.env.BACKEND_PUBLIC_BASE_URL);
  if (explicit) {
    return explicit;
  }
  const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
  const host = req.headers['x-forwarded-host'] || req.get('host');
  return `${proto}://${host}`;
}

function formatOrderDate(date = new Date()) {
  const pad = (value) => value.toString().padStart(2, '0');
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ${pad(
    date.getUTCHours(),
  )}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`;
}

function parseAmount(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, value);
  }
  if (typeof value === 'string') {
    const cleaned = value.replace(/[^\d.]/g, '');
    if (!cleaned) {
      return 0;
    }
    const parsed = Number.parseFloat(cleaned);
    return Number.isFinite(parsed) ? Math.max(0, parsed) : 0;
  }
  return 0;
}

function resolveProductAmount(product) {
  const candidates = [
    product.amount,
    product.price,
    product.amountPkr,
    product.unitAmount,
    product.priceLabel,
  ];
  for (const candidate of candidates) {
    const amount = parseAmount(candidate);
    if (amount > 0) {
      return amount;
    }
  }
  return 0;
}

function toAmountString(amount) {
  return amount.toFixed(2);
}

function buildBasketId(uid, productId) {
  const safeProductId = normalizeValue(productId).replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 24);
  const timestamp = Date.now();
  return `ae_${uid.slice(0, 8)}_${safeProductId}_${timestamp}`;
}

function normalizeSubscriptionDocId(userId, therapistId) {
  return `${normalizeValue(userId)}_${normalizeValue(therapistId)}`;
}

function isSuccessStatus(statusValue, responseCodeValue) {
  const status = normalizeValue(statusValue).toLowerCase();
  const responseCode = normalizeValue(responseCodeValue).toLowerCase();
  const successStatuses = new Set(['success', 'successful', 'completed', 'paid', 'processed', 'active', '00']);
  const successCodes = new Set(['00', '0', 'success', 'successful']);
  return successStatuses.has(status) || successCodes.has(responseCode);
}

function normalizeProviderPayload(rawPayload) {
  const payload = rawPayload || {};
  const basketId =
    payload.BASKET_ID ||
    payload.basket_id ||
    payload.order_id ||
    payload.ORDER_ID ||
    payload.merchant_basket_id ||
    '';
  const transactionId =
    payload.transaction_id ||
    payload.TRANSACTION_ID ||
    payload.pp_TxnRefNo ||
    payload.TxnRefNo ||
    payload.txn_ref_no ||
    '';
  const responseCode =
    payload.RESPONSE_CODE ||
    payload.response_code ||
    payload.ERR_CODE ||
    payload.err_code ||
    payload.ERROR_CODE ||
    payload.error_code ||
    payload.RespCode ||
    payload.respCode ||
    payload.code ||
    '';
  const status =
    payload.TRANSACTION_STATUS ||
    payload.transaction_status ||
    payload.STATUS ||
    payload.status ||
    payload.txn_status ||
    payload.message ||
    '';

  return {
    basketId: normalizeValue(basketId),
    transactionId: normalizeValue(transactionId),
    responseCode: normalizeValue(responseCode),
    status: normalizeValue(status),
    raw: payload,
  };
}

function verifyPayFastValidationHash(normalizedPayload) {
  const payload = normalizedPayload.raw || {};
  const providedHash = normalizeValue(
    payload.VALIDATION_HASH ||
      payload.validation_hash ||
      payload.HASH ||
      payload.hash ||
      payload.SECURE_HASH ||
      payload.secure_hash,
  ).toLowerCase();
  const errorCode = normalizeValue(
    payload.ERR_CODE ||
      payload.err_code ||
      payload.ERROR_CODE ||
      payload.error_code ||
      payload.RESPONSE_CODE ||
      payload.response_code ||
      normalizedPayload.responseCode,
  );

  if (!providedHash) {
    return { verified: false, reason: 'Missing validation hash in webhook payload', errorCode };
  }
  if (!normalizedPayload.basketId || !errorCode) {
    return { verified: false, reason: 'Missing basket id or error code for hash verification', errorCode };
  }

  const hashInput = `${normalizedPayload.basketId}|${payfastConfig.securedKey}|${payfastConfig.merchantId}|${errorCode}`;
  const computedHash = crypto.createHash('sha256').update(hashInput, 'utf8').digest('hex').toLowerCase();
  const verified = computedHash === providedHash;

  return {
    verified,
    reason: verified ? '' : 'Validation hash mismatch',
    errorCode,
    providedHash,
    computedHash,
  };
}

function escapeHtml(value) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function buildAutoPostHtml(actionUrl, fields) {
  const escapedAction = escapeHtml(actionUrl);
  const inputs = Object.entries(fields)
    .filter(([, value]) => normalizeValue(value) !== '')
    .map(([key, value]) => {
      const escapedKey = escapeHtml(key);
      const escapedValue = escapeHtml(value.toString());
      return `<input type="hidden" name="${escapedKey}" value="${escapedValue}" />`;
    })
    .join('\n');

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Redirecting to PayFast</title>
  </head>
  <body style="font-family: Arial, sans-serif; background:#f7fafc; color:#1f2937;">
    <div style="max-width:560px;margin:64px auto;padding:24px;background:white;border-radius:12px;box-shadow:0 2px 20px rgba(0,0,0,0.08);">
      <h2 style="margin-top:0;">Redirecting to secure checkout...</h2>
      <p style="line-height:1.45;">If you are not redirected automatically, click the button below.</p>
      <form id="payfast-checkout" method="post" action="${escapedAction}">
        ${inputs}
        <button type="submit" style="margin-top:12px;padding:10px 14px;border:0;border-radius:8px;background:#16a34a;color:white;cursor:pointer;">Continue to PayFast</button>
      </form>
    </div>
    <script>
      window.setTimeout(function () {
        var form = document.getElementById('payfast-checkout');
        if (form) form.submit();
      }, 50);
    </script>
  </body>
</html>`;
}

const payfastConfig = {
  provider: normalizeValue(process.env.PAYMENT_PROVIDER) || 'payfast_pk',
  baseUrl: normalizeBaseUrl(
    process.env.PAYFAST_BASE_URL || 'https://ipguat.apps.net.pk/Ecommerce/api/Transaction',
  ),
  accessTokenPath: normalizeValue(process.env.PAYFAST_ACCESS_TOKEN_PATH) || '/GetAccessToken',
  postTransactionPath: normalizeValue(process.env.PAYFAST_POST_TRANSACTION_PATH) || '/PostTransaction',
  statusPath: normalizeValue(process.env.PAYFAST_STATUS_PATH) || '/Inquiry',
  merchantId: normalizeValue(process.env.PAYFAST_MERCHANT_ID),
  securedKey: normalizeValue(process.env.PAYFAST_SECURED_KEY),
  merchantName: normalizeValue(process.env.PAYFAST_MERCHANT_NAME) || 'AutiEase',
  currencyCode: normalizeValue(process.env.PAYFAST_CURRENCY_CODE) || 'PKR',
  txDescription:
    normalizeValue(process.env.PAYFAST_TXN_DESC) || 'AutiEase Professional Support Monthly Subscription',
  version: normalizeValue(process.env.PAYFAST_VERSION) || 'MERCHANTCART-0.1',
  procCode: normalizeValue(process.env.PAYFAST_PROCCODE) || '00',
  tranType: normalizeValue(process.env.PAYFAST_TRAN_TYPE) || 'ECOMM_PURCHASE',
  storeId: normalizeValue(process.env.PAYFAST_STORE_ID),
  customerMobileDefault: normalizeValue(process.env.PAYFAST_CUSTOMER_MOBILE_DEFAULT) || '03001234567',
  checkoutUrlField: normalizeValue(process.env.PAYFAST_CHECKOUT_URL_FIELD),
  signatureStatic: normalizeValue(process.env.PAYFAST_SIGNATURE_STATIC),
  strictWebhookVerification: isTruthy(process.env.PAYFAST_STRICT_WEBHOOK_VERIFICATION),
};

function ensurePayFastConfigured() {
  if (!payfastConfig.baseUrl || !payfastConfig.merchantId || !payfastConfig.securedKey) {
    throw new Error(
      'PayFast is not configured. Required: PAYFAST_BASE_URL, PAYFAST_MERCHANT_ID, PAYFAST_SECURED_KEY.',
    );
  }
}

function payFastUrl(path) {
  const normalizedPath = path.startsWith('/') ? path : `/${path}`;
  return `${payfastConfig.baseUrl}${normalizedPath}`;
}

let tokenCache = {
  token: null,
  expiresAtMs: 0,
};

async function getPayFastAccessToken({ basketId, amount }) {
  const now = Date.now();
  if (tokenCache.token && tokenCache.expiresAtMs > now + 30000) {
    return tokenCache.token;
  }

  ensurePayFastConfigured();
  const body = new URLSearchParams({
    MERCHANT_ID: payfastConfig.merchantId,
    SECURED_KEY: payfastConfig.securedKey,
    BASKET_ID: basketId,
    TXNAMT: toAmountString(amount),
    CURRENCY_CODE: payfastConfig.currencyCode,
  });

  const response = await fetch(payFastUrl(payfastConfig.accessTokenPath), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`PayFast access token request failed (${response.status}): ${text}`);
  }

  const payload = await response.json();
  const token = normalizeValue(payload.ACCESS_TOKEN || payload.access_token || payload.token);
  if (!token) {
    throw new Error('PayFast access token response did not include ACCESS_TOKEN.');
  }

  const expiresInSeconds = Number.parseInt(payload.EXPIRES_IN || payload.expires_in || '600', 10);
  tokenCache = {
    token,
    expiresAtMs: now + (Number.isFinite(expiresInSeconds) ? expiresInSeconds : 600) * 1000,
  };
  return token;
}

function addDays(date, days) {
  const result = new Date(date.getTime());
  result.setUTCDate(result.getUTCDate() + days);
  return result;
}

async function syncUserSubscriptionEntitlements(userId) {
  const activeSnapshot = await db
    .collection('subscriptions')
    .where('userId', '==', userId)
    .where('status', 'in', ['active', 'trialing'])
    .limit(1)
    .get();
  const active = !activeSnapshot.empty;

  await db.collection('users').doc(userId).set(
    {
      entitlements: {
        professionalSupport: active,
        chatAccess: active,
      },
      subscriptionTier: active ? 'professional-support' : 'free',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

async function updateTherapistThreadAccess(userId, therapistId, active) {
  const normalizedUserId = normalizeValue(userId);
  const normalizedTherapistId = normalizeValue(therapistId);
  if (!normalizedUserId || !normalizedTherapistId) {
    return;
  }
  const threadSnapshot = await db
    .collection('therapist_threads')
    .where('parentId', '==', normalizedUserId)
    .where('therapistId', '==', normalizedTherapistId)
    .get();

  if (threadSnapshot.empty) {
    return;
  }

  const batch = db.batch();
  for (const doc of threadSnapshot.docs) {
    batch.set(
      doc.ref,
      {
        status: active ? 'active' : 'canceled',
        postCancelVisible: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
  await batch.commit();
}

async function markPaymentEventProcessed(eventId, payload) {
  const ref = db.collection('payment_events').doc(eventId);
  try {
    await ref.create({
      processedAt: admin.firestore.FieldValue.serverTimestamp(),
      payload,
    });
    return true;
  } catch (error) {
    if (error?.code === 6 || error?.code === 'already-exists') {
      return false;
    }
    throw error;
  }
}

async function findSubscriptionByBasketId(basketId) {
  const snapshot = await db
    .collection('subscriptions')
    .where('basketId', '==', basketId)
    .limit(1)
    .get();
  if (snapshot.empty) {
    return null;
  }
  return snapshot.docs[0];
}

async function verifyTransactionWithGateway(normalizedPayload, expectedAmount) {
  const transactionId = normalizedPayload.transactionId;
  const basketId = normalizedPayload.basketId;
  if (!transactionId && !basketId) {
    return { verified: false, reason: 'Missing transaction identifiers' };
  }

  try {
    const token = await getPayFastAccessToken({
      basketId: basketId || `verify_${Date.now()}`,
      amount: expectedAmount > 0 ? expectedAmount : 1,
    });

    const query = new URLSearchParams();
    if (transactionId) {
      query.set('transaction_id', transactionId);
    }
    if (basketId) {
      query.set('basket_id', basketId);
    }

    const statusUrl = `${payFastUrl(payfastConfig.statusPath)}${query.toString() ? `?${query.toString()}` : ''}`;
    const response = await fetch(statusUrl, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    if (!response.ok) {
      const text = await response.text();
      return { verified: false, reason: `Status API failed (${response.status}): ${text}` };
    }

    const payload = await response.json();
    const status =
      payload.status ||
      payload.transaction_status ||
      payload.TRANSACTION_STATUS ||
      payload.message ||
      '';
    const responseCode = payload.code || payload.response_code || payload.RESPONSE_CODE || '';
    const verified = isSuccessStatus(status, responseCode);

    return {
      verified,
      status: normalizeValue(status),
      responseCode: normalizeValue(responseCode),
      payload,
      reason: verified ? '' : 'Gateway status did not indicate success',
    };
  } catch (error) {
    return { verified: false, reason: error?.message || String(error) };
  }
}

async function reconcileExpiredSubscriptions() {
  const now = admin.firestore.Timestamp.now();
  const snapshot = await db
    .collection('subscriptions')
    .where('status', 'in', ['active', 'trialing'])
    .where('currentPeriodEnd', '<=', now)
    .get();

  if (snapshot.empty) {
    return { expiredCount: 0 };
  }

  const updatedUserIds = new Set();
  const updatedPairs = [];
  const batch = db.batch();

  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    const userId = normalizeValue(data.userId);
    const therapistId = normalizeValue(data.therapistId);
    if (!userId) {
      continue;
    }
    batch.set(
      doc.ref,
      {
        status: 'expired',
        isActive: false,
        cancelAtPeriodEnd: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    updatedUserIds.add(userId);
    if (therapistId) {
      updatedPairs.push({ userId, therapistId });
    }
  }

  await batch.commit();

  for (const pair of updatedPairs) {
    await updateTherapistThreadAccess(pair.userId, pair.therapistId, false);
  }
  for (const userId of updatedUserIds) {
    await syncUserSubscriptionEntitlements(userId);
  }

  return { expiredCount: snapshot.size };
}

initFirebaseAdmin();
const db = admin.firestore();
const allowedOrigins = parseAllowedOrigins();
const mockPaymentsEnabled = isTruthy(process.env.PAYMENTS_MOCK_MODE) || isTruthy(process.env.MOCK_PAYMENTS);

app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.length === 0 || allowedOrigins.includes(origin)) {
        callback(null, true);
        return;
      }
      callback(new Error('Origin not allowed by CORS policy'));
    },
  }),
);

app.use(express.urlencoded({ extended: false }));
app.use(express.json());

app.get('/health', (_req, res) => {
  res.status(200).json({ ok: true, service: 'autiease-payment-backend', provider: payfastConfig.provider });
});

app.get('/api/v1/checkout/redirect/:checkoutId', async (req, res) => {
  try {
    const checkoutId = normalizeValue(req.params.checkoutId);
    if (!checkoutId) {
      return jsonError(res, 400, 'Missing checkout id');
    }
    const checkoutDoc = await db.collection('checkout_sessions').doc(checkoutId).get();
    if (!checkoutDoc.exists) {
      return jsonError(res, 404, 'Checkout session not found');
    }

    const checkoutData = checkoutDoc.data() || {};
    if (checkoutData.status !== 'pending') {
      return jsonError(res, 400, 'Checkout session is no longer pending');
    }

    const html = buildAutoPostHtml(payFastUrl(payfastConfig.postTransactionPath), checkoutData.formFields || {});
    res.status(200).set('Content-Type', 'text/html; charset=utf-8').send(html);
  } catch (error) {
    console.error('Checkout redirect failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to initialize checkout');
  }
});

app.post('/api/v1/checkout/session', requireAuth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { therapistId, productId, successUrl, cancelUrl } = req.body || {};

    if (!therapistId || !productId || !successUrl || !cancelUrl) {
      return jsonError(res, 400, 'Missing checkout parameters');
    }
    const normalizedTherapistId = normalizeValue(therapistId);
    const normalizedProductId = normalizeValue(productId);
    if (!normalizedTherapistId || !normalizedProductId) {
      return jsonError(res, 400, 'Invalid checkout parameters');
    }

    const therapistSnapshot = await db.collection('therapist_profiles').doc(normalizedTherapistId).get();
    if (!therapistSnapshot.exists) {
      return jsonError(res, 404, 'Therapist profile not found');
    }
    const therapist = therapistSnapshot.data() || {};
    const therapistProductId = normalizeValue(therapist.subscriptionProductId);
    if (!therapistProductId) {
      return jsonError(res, 400, 'Therapist is not configured with a subscription product');
    }
    if (therapistProductId !== normalizedProductId) {
      return jsonError(res, 400, 'Therapist and product mapping mismatch');
    }

    const productSnapshot = await db.collection('subscription_products').doc(normalizedProductId).get();
    if (!productSnapshot.exists) {
      return jsonError(res, 404, 'Subscription product not found');
    }
    const product = productSnapshot.data() || {};
    if (product.isActive === false) {
      return jsonError(res, 400, 'Subscription product is not active');
    }

    const userSnapshot = await db.collection('users').doc(uid).get();
    if (!userSnapshot.exists) {
      return jsonError(res, 404, 'User profile not found');
    }
    const user = userSnapshot.data() || {};

    const amount = resolveProductAmount(product);
    if (amount <= 0) {
      return jsonError(
        res,
        400,
        'Subscription product amount is missing. Add numeric `amount` to subscription_products.',
      );
    }

    const basketId = buildBasketId(uid, normalizedProductId);
    const checkoutId = basketId;
    const subscriptionId = normalizeSubscriptionDocId(uid, normalizedTherapistId);
    const transactionAmount = toAmountString(amount);

    if (mockPaymentsEnabled) {
      await db.collection('subscriptions').doc(subscriptionId).set(
        {
          userId: uid,
          therapistId: normalizedTherapistId,
          productId: normalizedProductId,
          provider: 'payfast_pk',
          providerTransactionId: `mock_txn_${Date.now()}`,
          providerCustomerRef: normalizeValue(user.email),
          lastPaymentRef: `mock_ref_${Date.now()}`,
          basketId,
          status: 'active',
          isActive: true,
          cancelAtPeriodEnd: false,
          currentPeriodEnd: admin.firestore.Timestamp.fromDate(addDays(new Date(), 30)),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          isMock: true,
        },
        { merge: true },
      );
      await updateTherapistThreadAccess(uid, normalizedTherapistId, true);
      await syncUserSubscriptionEntitlements(uid);

      return res.status(200).json({
        sessionId: subscriptionId,
        url: `${resolveCheckoutBaseUrl(req)}/api/v1/payment/return/success?mock=1&basket_id=${encodeURIComponent(
          basketId,
        )}`,
        mock: true,
      });
    }

    ensurePayFastConfigured();

    const token = await getPayFastAccessToken({ basketId, amount });
    const baseUrl = resolveCheckoutBaseUrl(req);
    const webhookUrl = `${baseUrl}/api/v1/payment/webhook`;

    const formFields = {
      CURRENCY_CODE: payfastConfig.currencyCode,
      MERCHANT_ID: payfastConfig.merchantId,
      MERCHANT_NAME: payfastConfig.merchantName,
      TOKEN: token,
      BASKET_ID: basketId,
      TXNAMT: transactionAmount,
      ORDER_DATE: formatOrderDate(),
      SUCCESS_URL: successUrl,
      FAILURE_URL: cancelUrl,
      CHECKOUT_URL: payfastConfig.checkoutUrlField || webhookUrl,
      CUSTOMER_EMAIL_ADDRESS: normalizeValue(user.email),
      CUSTOMER_MOBILE_NO: normalizeValue(user.phone) || payfastConfig.customerMobileDefault,
      SIGNATURE: payfastConfig.signatureStatic,
      VERSION: payfastConfig.version,
      TXNDESC: payfastConfig.txDescription,
      PROCCODE: payfastConfig.procCode,
      TRAN_TYPE: payfastConfig.tranType,
      STORE_ID: payfastConfig.storeId,
      RECURRING_TXN: '',
    };

    await db.collection('checkout_sessions').doc(checkoutId).set(
      {
        userId: uid,
        therapistId: normalizedTherapistId,
        productId: normalizedProductId,
        subscriptionId,
        basketId,
        amount,
        status: 'pending',
        provider: 'payfast_pk',
        formFields,
        successUrl,
        cancelUrl,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await db.collection('subscriptions').doc(subscriptionId).set(
      {
        userId: uid,
        therapistId: normalizedTherapistId,
        productId: normalizedProductId,
        provider: 'payfast_pk',
        status: 'pending',
        isActive: false,
        cancelAtPeriodEnd: false,
        basketId,
        amount,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return res.status(200).json({
      sessionId: subscriptionId,
      url: `${baseUrl}/api/v1/checkout/redirect/${encodeURIComponent(checkoutId)}`,
    });
  } catch (error) {
    console.error('Checkout session failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to create checkout session');
  }
});

app.post('/api/v1/payment/webhook', async (req, res) => {
  try {
    const normalized = normalizeProviderPayload(req.body || {});
    if (!normalized.basketId) {
      return jsonError(res, 400, 'Missing basket id in webhook payload');
    }

    const eventKey = normalized.transactionId || `${normalized.basketId}:${normalized.responseCode}:${normalized.status}`;
    const eventId = crypto.createHash('sha256').update(eventKey).digest('hex');
    const wasInserted = await markPaymentEventProcessed(eventId, normalized.raw);
    if (!wasInserted) {
      return res.status(200).json({ received: true, duplicate: true });
    }

    const subscriptionDoc = await findSubscriptionByBasketId(normalized.basketId);
    if (!subscriptionDoc) {
      return jsonError(res, 404, 'Subscription not found for basket');
    }
    const subscription = subscriptionDoc.data() || {};
    const subscriptionUserId = normalizeValue(subscription.userId);
    const therapistId = normalizeValue(subscription.therapistId);

    const amount = parseAmount(subscription.amount);
    const gatewayVerification = payfastConfig.strictWebhookVerification
      ? await verifyTransactionWithGateway(normalized, amount)
      : {
          verified: false,
          status: '',
          responseCode: '',
          reason: 'Skipped gateway inquiry verification (strict mode disabled).',
        };
    const hashVerification = verifyPayFastValidationHash(normalized);
    const webhookSuccess = isSuccessStatus(normalized.status, normalized.responseCode);
    const isSuccess = payfastConfig.strictWebhookVerification
      ? gatewayVerification.verified && hashVerification.verified
      : webhookSuccess;

    if (isSuccess) {
      await subscriptionDoc.ref.set(
        {
          provider: 'payfast_pk',
          providerTransactionId: normalized.transactionId,
          lastPaymentRef: normalized.transactionId || normalized.basketId,
          status: 'active',
          isActive: true,
          cancelAtPeriodEnd: false,
          currentPeriodEnd: admin.firestore.Timestamp.fromDate(addDays(new Date(), 30)),
          verification: {
            verifiedByGateway: gatewayVerification.verified,
            verifiedByHash: hashVerification.verified,
            responseCode: gatewayVerification.responseCode || normalized.responseCode,
            status: gatewayVerification.status || normalized.status,
            hashErrorCode: hashVerification.errorCode || normalized.responseCode,
            hashProvided: hashVerification.providedHash || '',
            hashComputed: hashVerification.computedHash || '',
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      if (subscriptionUserId && therapistId) {
        await updateTherapistThreadAccess(subscriptionUserId, therapistId, true);
      }
      if (subscriptionUserId) {
        await syncUserSubscriptionEntitlements(subscriptionUserId);
      }
      const checkoutSessionSnapshot = await db
        .collection('checkout_sessions')
        .where('basketId', '==', normalized.basketId)
        .limit(1)
        .get();
      if (!checkoutSessionSnapshot.empty) {
        await checkoutSessionSnapshot.docs[0].ref.set(
          {
            status: 'completed',
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }

      return res.status(200).json({ received: true, status: 'active' });
    }

    await subscriptionDoc.ref.set(
      {
        status: 'payment_failed',
        isActive: false,
        cancelAtPeriodEnd: true,
        verification: {
          verifiedByGateway: gatewayVerification.verified,
          verifiedByHash: hashVerification.verified,
          responseCode: gatewayVerification.responseCode || normalized.responseCode,
          status: gatewayVerification.status || normalized.status,
          hashErrorCode: hashVerification.errorCode || normalized.responseCode,
          hashProvided: hashVerification.providedHash || '',
          hashComputed: hashVerification.computedHash || '',
          reason:
            (payfastConfig.strictWebhookVerification &&
              ((!gatewayVerification.verified && gatewayVerification.reason) ||
                (!hashVerification.verified && hashVerification.reason))) ||
            'Transaction failed',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    if (subscriptionUserId && therapistId) {
      await updateTherapistThreadAccess(subscriptionUserId, therapistId, false);
    }
    if (subscriptionUserId) {
      await syncUserSubscriptionEntitlements(subscriptionUserId);
    }

    return res.status(200).json({ received: true, status: 'failed' });
  } catch (error) {
    console.error('Payment webhook processing failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to process payment webhook');
  }
});

app.get('/api/v1/payment/return/success', (_req, res) => {
  res.status(200).send('Payment processed. You can return to AutiEase app.');
});

app.get('/api/v1/payment/return/failure', (_req, res) => {
  res.status(200).send('Payment was not completed. You can return to AutiEase app.');
});

app.post('/api/v1/subscription/cancel', requireAuth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { subscriptionId } = req.body || {};
    if (!subscriptionId) {
      return jsonError(res, 400, 'subscriptionId is required');
    }

    const subscriptionRef = db.collection('subscriptions').doc(subscriptionId);
    const snapshot = await subscriptionRef.get();
    if (!snapshot.exists) {
      return jsonError(res, 404, 'Subscription not found');
    }

    const subscription = snapshot.data() || {};
    if (normalizeValue(subscription.userId) !== uid) {
      return jsonError(res, 403, 'Cannot cancel another user subscription');
    }

    await subscriptionRef.set(
      {
        cancelAtPeriodEnd: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    const currentPeriodEnd = subscription.currentPeriodEnd;
    const shouldDeactivateNow = !(currentPeriodEnd instanceof admin.firestore.Timestamp) || currentPeriodEnd.toDate() <= new Date();
    if (shouldDeactivateNow) {
      await subscriptionRef.set(
        {
          status: 'canceled',
          isActive: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      await updateTherapistThreadAccess(uid, normalizeValue(subscription.therapistId), false);
    }
    await syncUserSubscriptionEntitlements(uid);

    return res.status(200).json({ status: shouldDeactivateNow ? 'canceled' : 'cancel_scheduled' });
  } catch (error) {
    console.error('Cancel subscription failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to cancel subscription');
  }
});

app.post('/api/v1/subscription/reactivate', requireAuth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { subscriptionId } = req.body || {};
    if (!subscriptionId) {
      return jsonError(res, 400, 'subscriptionId is required');
    }

    const subscriptionRef = db.collection('subscriptions').doc(subscriptionId);
    const snapshot = await subscriptionRef.get();
    if (!snapshot.exists) {
      return jsonError(res, 404, 'Subscription not found');
    }

    const subscription = snapshot.data() || {};
    if (normalizeValue(subscription.userId) !== uid) {
      return jsonError(res, 403, 'Cannot reactivate another user subscription');
    }

    const currentPeriodEnd = subscription.currentPeriodEnd;
    const periodStillActive = currentPeriodEnd instanceof admin.firestore.Timestamp && currentPeriodEnd.toDate() > new Date();

    await subscriptionRef.set(
      {
        cancelAtPeriodEnd: false,
        status: periodStillActive ? 'active' : 'expired',
        isActive: periodStillActive,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    await updateTherapistThreadAccess(uid, normalizeValue(subscription.therapistId), periodStillActive);
    await syncUserSubscriptionEntitlements(uid);

    return res.status(200).json({ status: periodStillActive ? 'reactivated' : 'expired_needs_renewal' });
  } catch (error) {
    console.error('Reactivate subscription failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to reactivate subscription');
  }
});

app.post('/api/v1/subscription/reconcile-expired', async (req, res) => {
  try {
    const expectedSecret = normalizeValue(process.env.RECONCILE_CRON_SECRET);
    if (expectedSecret) {
      const provided = normalizeValue(req.header('x-cron-secret'));
      if (!provided || provided !== expectedSecret) {
        return jsonError(res, 401, 'Unauthorized cron request');
      }
    }

    const result = await reconcileExpiredSubscriptions();
    return res.status(200).json({ ok: true, ...result });
  } catch (error) {
    console.error('Reconcile expired subscriptions failed:', error?.message || error);
    return jsonError(res, 500, 'Unable to reconcile subscriptions');
  }
});

const port = Number.parseInt(process.env.PORT || '8080', 10);
app.listen(port, () => {
  console.log(`AutiEase payment backend running on port ${port}`);
});
