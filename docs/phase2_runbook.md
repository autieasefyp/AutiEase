# Phase 2 Runbook

This runbook is the release checklist for Phase 2 hardening.

## Scope Completed
- Session guard routing hardened in Flutter screens (parent/therapist/authenticated routes).
- Strict email verification enforced before usable login session.
- Backend user cleanup hardened for both deletion directions:
  - Firestore `users/{uid}` deletion cascades to Auth + dependent data.
  - Firebase Auth user deletion cascades to Firestore `users/{uid}` + dependent data.
- Local admin cleanup script added for stale test accounts.
- Billing path migrated to GoPayFast backend checkout (PKR, per-therapist).

## Deploy Commands (Core App)
Run from repo root:

1. Select project:
`firebase use autiease-fyp-2026`
2. Deploy rules:
`firebase deploy --only firestore:rules`

## Payments Setup
- Backend guide: `docs/payfast_payment_backend.md`
- Set `therapist_profiles/{therapistId}.subscriptionProductId` for each sellable therapist.
- Ensure matching `subscription_products/{id}` docs exist with PKR `amount`.

## Regression Commands
Run from repo root:

1. Static analysis:
`flutter analyze`
2. Unit/widget tests:
`flutter test`
3. Manual auth regression:
Follow `docs/auth_regression_checklist.md`.

## Stale User Cleanup
Run from `functions/`:

1. Install dependencies (once):
`npm install`
2. Authenticate ADC:
`gcloud auth application-default login`
3. Set project id in PowerShell:
`$env:FIREBASE_PROJECT_ID='autiease-fyp-2026'`
4. Cleanup by email:
`npm run cleanup:user -- --email <email>`
5. Cleanup by uid:
`npm run cleanup:user -- --uid <uid>`

The script deletes:
- Auth user
- `users/{uid}`
- `therapist_profiles/{uid}`
- parent-owned `child_profiles`, `child_assignments`, `dashboard_snapshots`
- child-linked `mood_logs`, `activity_progress`
- user-linked `therapist_threads` (recursive, includes `messages`)
- `subscriptions` by `userId`
- `feedback` by `userId`

## Release Artifacts
Run from repo root:

1. Debug/QA APK:
`flutter build apk --debug`
2. Release APK:
`flutter build apk --release`
3. Play Store AAB:
`flutter build appbundle --release`

Primary output paths:
- `build/app/outputs/flutter-apk/app-debug.apk`
- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`
