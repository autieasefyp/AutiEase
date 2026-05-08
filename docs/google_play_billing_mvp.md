# Google Play Billing MVP (Android-First)

This app now uses Google Play Billing for parent-to-therapist monthly subscriptions on Android.

## Core model
- One Firestore subscription document per `user + therapist`.
- Document id format: `{uid}_{therapistId}`.
- Source of Play product mapping: `therapist_profiles/{therapistId}.playProductId`.

Required subscription fields written by app:
- `userId`
- `therapistId`
- `productId`
- `purchaseToken`
- `status`
- `isActive`
- `cancelAtPeriodEnd`
- `currentPeriodEnd`
- `platform = "android_play"`
- `updatedAt`
- `createdAt`

## Play Console setup
1. Create the Android app for package `com.example.autiease`.
2. Create an auto-renewing monthly subscription product for each therapist you want to sell.
3. Copy each Play product id into that therapist profile's `playProductId` field in Firestore.
4. Publish products to a test track and use test accounts.

## App behavior
- Android:
  - Subscription purchase uses Google Play Billing.
  - `Restore Purchases` re-syncs active purchases.
  - Cancel opens Google Play subscription management.
- iOS/Web:
  - Subscription purchase is disabled and shown as Android-only.

## Security warning (MVP)
This release accepts client-written subscription entitlements without server-side purchase token verification.  
This is intentionally MVP-only and vulnerable to entitlement spoofing compared with a backend-verified model.
