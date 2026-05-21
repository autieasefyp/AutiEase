# AutiEase E2E Setup Guide (Client)

This document explains how to run AutiEase end-to-end with PayFast payments.

## 1) Do we need backend if client uses APK only?

Yes. APK alone is **not enough** for real payments.

- The APK calls the payment backend API.
- PayFast sends IPN callback to backend webhook.
- Backend verifies transaction status + validation hash and updates Firebase subscription state.

If backend is down, payment flow will fail or not activate subscription.

## 2) Current architecture

- Mobile app (APK) -> `POST /api/v1/checkout/session`
- Backend redirects user to PayFast hosted checkout
- PayFast -> backend webhook `POST /api/v1/payment/webhook`
- Backend verifies:
  - Gateway Inquiry API status
  - Validation hash: `basket_id|secured_key|merchant_id|err_code` (SHA-256)
- Backend updates Firestore subscription and entitlements

## 3) Backend deployment (Render)

Service type: **Web Service (Node)**  
Root directory: `payment-backend`  
Build command: `npm install`  
Start command: `npm start`  
Health check path: `/health`

Required environment variables:

- NODE_ENV=production
- PAYMENT_PROVIDER=payfast_pk
- FIREBASE_PROJECT_ID=autiease-fyp-2026
- FIREBASE_SERVICE_ACCOUNT_JSON=<paste full JSON from secure secret store; never commit>
- PAYFAST_BASE_URL=https://ipguat.apps.net.pk/Ecommerce/api/Transaction
- PAYFAST_MERCHANT_ID=103
- PAYFAST_SECURED_KEY=<your payfast secured key>
- PAYFAST_MERCHANT_NAME=AutiEase
- PAYFAST_CURRENCY_CODE=PKR
- PAYFAST_STRICT_WEBHOOK_VERIFICATION=true
- PAYMENT_REDIRECT_BASE_URL=https://autiease-payment-backend.onrender.com
- PAYFAST_CHECKOUT_URL_FIELD=https://autiease-payment-backend.onrender.com/api/v1/payment/webhook
- ALLOWED_ORIGINS=

After saving env vars, run **Manual Deploy -> Deploy latest commit**.

## 4) Verify backend is live

Open:

- `https://autiease-payment-backend.onrender.com/health`

Expected:

- JSON with `ok: true`

## 5) APK configuration requirement

The APK must be built with:

- `PAYMENT_BACKEND_BASE_URL=https://<autiease-payment-backend.onrender.com`

If APK was built with wrong/missing backend URL, checkout will not work and a new APK build is required.

Optional defines used by app:

- `PAYMENT_SUCCESS_URL=https://example.com/payment-success`
- `PAYMENT_CANCEL_URL=https://example.com/payment-failure`

## 6) UAT test payment steps

1. Start app and login as test user.
2. Open subscription/professional support checkout flow.
3. Complete PayFast UAT payment with:
   - Card number: `2223000000000000007`
   - Expiry: `01/39`
   - CVV: `100`
4. Wait for redirect after payment.
5. Confirm backend processed webhook and activated subscription.

## 7) How to confirm payment worked end-to-end

Check all 4:

1. Render logs show webhook hit:
   - `POST /api/v1/payment/webhook`
2. Firestore `subscriptions` record for user is:
   - `status: active`
   - `isActive: true`
3. Verification fields are true:
   - `verification.verifiedByGateway: true`
   - `verification.verifiedByHash: true`
4. User entitlements updated:
   - `users/{userId}.entitlements.professionalSupport: true`
   - `users/{userId}.entitlements.chatAccess: true`

## 8) Quick troubleshooting

- `Missing checkout parameters`: app did not send required checkout payload.
- `Missing basket id in webhook payload`: invalid callback payload from provider/test.
- `Validation hash mismatch`: wrong `PAYFAST_SECURED_KEY`, wrong merchant id, or mismatched `err_code`.
- `Status API failed`: PayFast Inquiry request failed; check network and credentials.
- Payment page opens but no subscription activation:
  - `PAYFAST_CHECKOUT_URL_FIELD` is wrong, or
  - backend not reachable, or
  - strict verification failed.

## 9) Temporary mock mode (no real gateway)

For non-gateway testing only:

- Set `PAYMENTS_MOCK_MODE=true`
- Deploy

Checkout will simulate success and activate subscription without real card/payment gateway.

## 10) Go-live checklist

Before production:

1. Replace UAT endpoint with live endpoint:
   - `PAYFAST_BASE_URL=https://ipg1.apps.net.pk/Ecommerce/api/Transaction`
2. Replace UAT merchant credentials with live credentials.
3. Keep strict verification on:
   - `PAYFAST_STRICT_WEBHOOK_VERIFICATION=true`
4. Ensure callback is your real backend:
   - `PAYFAST_CHECKOUT_URL_FIELD=https://<prod-backend>/api/v1/payment/webhook`
5. Run one real production smoke transaction with client supervision.
