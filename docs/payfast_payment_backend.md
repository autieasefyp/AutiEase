# GoPayFast Payment Backend (AutiEase)

This is the active billing integration for AutiEase FYP delivery.

## What it does
- Creates hosted checkout sessions through backend-authenticated GoPayFast setup.
- Handles payment callbacks via `POST /api/v1/payment/webhook`.
- Activates/deactivates Firestore subscription entitlements.
- Supports monthly-renew lifecycle (`cancelAtPeriodEnd`, expiry reconciliation).
- Uses deterministic subscription ids: `subscriptions/{userId}_{therapistId}`.

## Backend setup
From `payment-backend/`:

```powershell
npm install
$env:FIREBASE_PROJECT_ID="autiease-fyp-2026"
$env:PAYFAST_BASE_URL="https://ipguat.apps.net.pk/Ecommerce/api/Transaction"
$env:PAYFAST_MERCHANT_ID="103"
$env:PAYFAST_SECURED_KEY="PzPx6ut-SVay7tCUMqG"
$env:PAYMENT_REDIRECT_BASE_URL="https://<your-backend-domain>"
npm start
```

UAT temporary testing mode:

```powershell
$env:PAYFAST_MERCHANT_NAME="AutiEase"
$env:PAYFAST_CURRENCY_CODE="PKR"
$env:PAYFAST_CHECKOUT_URL_FIELD="https://webhook.site/your-generated-id"
$env:PAYFAST_STRICT_WEBHOOK_VERIFICATION="false"
$env:RECONCILE_CRON_SECRET="<random-secret>"
$env:ALLOWED_ORIGINS="https://<your-web-origin>"
```

Notes for UAT temporary mode:
- `PAYFAST_STRICT_WEBHOOK_VERIFICATION=false` means webhook success/failure is decided from webhook payload status only.
- With `PAYFAST_CHECKOUT_URL_FIELD` pointing to `webhook.site`, PayFast IPN goes to webhook.site instead of AutiEase backend.
- Because backend webhook is bypassed in this mode, automatic subscription activation/deactivation in Firestore will not run from real gateway callbacks.

## Flutter launch defines

```powershell
flutter run `
  --dart-define=PAYMENT_BACKEND_BASE_URL=https://<your-backend-domain> `
  --dart-define=PAYMENT_SUCCESS_URL=https://example.com/payment-success `
  --dart-define=PAYMENT_CANCEL_URL=https://example.com/payment-failure
```

## Demo mode (no live gateway)

```powershell
$env:PAYMENTS_MOCK_MODE="true"
```

In demo mode, backend simulates a successful monthly subscription.

## Checkout API contract
- `POST /api/v1/checkout/session` expects:
  - `therapistId`
  - `productId`
  - `successUrl`
  - `cancelUrl`
- Backend rejects checkout if therapist-to-product mapping does not match.

## Firestore expectations
- `therapist_profiles/{therapistId}` should include:
  - `subscriptionProductId` (string; must match a `subscription_products/{id}`)
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

## Validation hash verification
When `PAYFAST_STRICT_WEBHOOK_VERIFICATION=true`, backend verifies PayFast IPN hash using:

`basket_id|secured_key|merchant_id|err_code`

SHA-256 hex digest (lowercase) is compared with hash returned by PayFast.

Payload keys accepted:
- hash: `validation_hash` / `VALIDATION_HASH` / `hash` / `HASH` / `secure_hash` / `SECURE_HASH`
- error code: `err_code` / `ERR_CODE` / `error_code` / `ERROR_CODE` / `response_code` / `RESPONSE_CODE`

Strict mode behavior:
- Requires gateway Inquiry API verification and validation hash match.
- If either check fails, subscription is marked `payment_failed`.

## Production switch checklist
- Set `PAYFAST_CHECKOUT_URL_FIELD` to your real backend callback:
  - `https://<your-backend-domain>/api/v1/payment/webhook`
- Keep `PAYFAST_STRICT_WEBHOOK_VERIFICATION=true`.
- Replace UAT credentials with live credentials.
- Rotate the UAT secured key shared in email/chat before go-live.
