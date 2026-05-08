# Firebase Migration

This app is configured to run against:

- `android/app/google-services.json`
- Android package id: `com.example.autiease`
- Firebase project id: `autiease-fyp-2026`

Important:
- `google-services.json` is client configuration, not an admin credential.
- The API key inside it identifies the Firebase project for client SDK calls. It is not a server secret.
- The app signs users up only when Firebase Auth is enabled and the Android app is registered in the active project.

## What needs to change

Current migration target is already selected:

1. Firebase project: `autiease-fyp-2026`
2. Add an Android app with package name `com.example.autiease`.
3. Enable Authentication providers you need:
   - Email/Password
   - Google
4. Create a Firestore database.
5. Download your new `google-services.json` into `android/app/google-services.json`.
6. If you will ship iOS later, add the iOS app and place `GoogleService-Info.plist` in `ios/Runner/`.
7. Log in with Firebase CLI:
   - `firebase login`
8. Configure FlutterFire:
   - `flutterfire configure --project autiease-fyp-2026`
9. Install Firebase resources:
   - `firebase use autiease-fyp-2026`
   - `firebase deploy --only firestore:rules`
10. For Functions, set required payment provider secrets before deploy:
   - `firebase functions:secrets:set PAYMENT_PROVIDER_SECRET_KEY`
   - `firebase functions:secrets:set PAYMENT_PROVIDER_WEBHOOK_SECRET`
11. Deploy functions:
   - `firebase deploy --only functions`

If you are on Spark (no Blaze), skip Functions for payments and use the external backend in:
- `docs/payfast_payment_backend.md`

## Seed data

The DB-driven parent shell requires seeded Firestore content, especially:

- `app_modules`
- `settings_entries`
- `content_categories`
- `content_items`
- `learning_modules`
- `daily_activity_templates`
- `therapist_profiles`
- `subscription_products`
- `legal_documents`

Seed source:

- `functions/seed/firestore.seed.json`

Seed command:

- `cd functions`
- `npm install`
- `FIREBASE_PROJECT_ID=<your-project-id> node scripts/seed-firestore.js`

The seed script supports two local auth paths:

- `GOOGLE_APPLICATION_CREDENTIALS=<path to service account json>`
- Application Default Credentials from `gcloud auth application-default login`
- Firebase CLI login with `firebase login` plus `FIREBASE_PROJECT_ID=<your-project-id>`

## Current repo status

- Firebase CLI is installed locally.
- FlutterFire CLI is installed locally.
- The app points to `autiease-fyp-2026` in `google-services.json` and `lib/firebase_options.dart`.
- Keep all future Firebase CLI and FlutterFire commands pinned to `autiease-fyp-2026`.

## Stale Test Account Cleanup

From `functions/`:

- Authenticate local ADC once:
  - `gcloud auth application-default login`
- Set project id in PowerShell:
  - `$env:FIREBASE_PROJECT_ID='autiease-fyp-2026'`

- Cleanup by email:
  - `npm run cleanup:user -- --email <email>`
- Cleanup by uid:
  - `npm run cleanup:user -- --uid <uid>`

This removes Auth + related Firestore data so stale docs do not remain after test cycles.
