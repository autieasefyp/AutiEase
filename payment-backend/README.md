# AutiEase Payment Backend (GoPayFast)

External payment backend for AutiEase subscription billing.

## Endpoints
- `GET /health`
- `POST /api/v1/checkout/session`
- `GET /api/v1/checkout/redirect/:checkoutId`
- `POST /api/v1/payment/webhook`
- `POST /api/v1/subscription/cancel`
- `POST /api/v1/subscription/reactivate`
- `POST /api/v1/subscription/reconcile-expired`

## Checkout contract
`POST /api/v1/checkout/session` requires:
- `therapistId`
- `productId`
- `successUrl`
- `cancelUrl`

Server validates that:
- `therapist_profiles/{therapistId}.subscriptionProductId` exists
- it matches `productId`
- the referenced `subscription_products/{productId}` is active

Subscription document id is deterministic:
- `subscriptions/{userId}_{therapistId}`

## Required env vars
- `FIREBASE_PROJECT_ID=autiease-fyp-2026`
- `PAYFAST_BASE_URL=https://ipguat.apps.net.pk/Ecommerce/api/Transaction`
- `PAYFAST_MERCHANT_ID=...`
- `PAYFAST_SECURED_KEY=...`
- One Firebase Admin auth mode:
  - `FIREBASE_SERVICE_ACCOUNT_JSON={...}`
  - or `GOOGLE_APPLICATION_CREDENTIALS=/path/service-account.json`

## Recommended env vars
- `PAYMENT_PROVIDER=payfast_pk`
- `PAYFAST_MERCHANT_NAME=AutiEase`
- `PAYFAST_CURRENCY_CODE=PKR`
- `PAYMENT_REDIRECT_BASE_URL=https://<your-backend-domain>`
- `PAYFAST_CHECKOUT_URL_FIELD=https://<your-backend-domain>/api/v1/payment/webhook`
- `PAYFAST_STRICT_WEBHOOK_VERIFICATION=true`
- `ALLOWED_ORIGINS=https://your-web-origin.example.com`
- `RECONCILE_CRON_SECRET=<random-secret>`

## Optional local/dev env vars
- `PAYMENTS_MOCK_MODE=true` (simulate successful monthly subscription)
- `MOCK_PAYMENTS=true` (legacy alias)

## Local run
1. `npm install`
2. Set env vars
3. `npm start`

Health check:
- `http://localhost:8080/health`

## Deploy presets included
- `render.yaml`
- `railway.json`
- `fly.toml`
- `Dockerfile`
