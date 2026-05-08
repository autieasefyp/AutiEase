# GoPayFast Payment Backend (AutiEase)

This is the active billing integration for AutiEase FYP delivery.

## What it does
- Creates hosted checkout sessions through backend-authenticated GoPayFast setup.
- Handles payment callbacks via `POST /api/v1/payment/webhook`.
- Activates/deactivates Firestore subscription entitlements.
- Supports monthly-renew lifecycle (`cancelAtPeriodEnd`, expiry reconciliation).

## Backend setup
From `payment-backend/`:

```powershell
npm install
$env:FIREBASE_PROJECT_ID="autiease-fyp-2026"
$env:PAYFAST_BASE_URL="https://ipguat.apps.net.pk/Ecommerce/api/Transaction"
$env:PAYFAST_MERCHANT_ID="<merchant-id>"
$env:PAYFAST_SECURED_KEY="<secured-key>"
$env:PAYMENT_REDIRECT_BASE_URL="https://<your-backend-domain>"
npm start
```

Optional (recommended):

```powershell
$env:PAYFAST_MERCHANT_NAME="AutiEase"
$env:PAYFAST_CURRENCY_CODE="PKR"
$env:PAYFAST_CHECKOUT_URL_FIELD="https://<your-backend-domain>/api/v1/payment/webhook"
$env:PAYFAST_STRICT_WEBHOOK_VERIFICATION="true"
$env:RECONCILE_CRON_SECRET="<random-secret>"
$env:ALLOWED_ORIGINS="https://<your-web-origin>"
```

## Flutter launch defines

```powershell
flutter run `
  --dart-define=PAYMENT_BACKEND_BASE_URL=https://<your-backend-domain> `
  --dart-define=PAYMENT_SUCCESS_URL=https://<your-success-url> `
  --dart-define=PAYMENT_CANCEL_URL=https://<your-cancel-url>
```

## Demo mode (no live gateway)

```powershell
$env:PAYMENTS_MOCK_MODE="true"
```

In demo mode, backend simulates a successful monthly subscription.

## Firestore expectations
- `subscription_products/{id}` should include:
  - `amount` (numeric)
  - `billingPlanId` (string; metadata)
  - `isActive=true`
- `app_modules/professional_support` should include:
  - `chatEnabled=true`
  - `paymentsEnabled=true`

## Scheduled expiry reconciliation
- Endpoint: `POST /api/v1/subscription/reconcile-expired`
- Header: `x-cron-secret: <RECONCILE_CRON_SECRET>` (if configured)
