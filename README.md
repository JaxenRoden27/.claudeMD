# Cipher Courier

Spring 2026 Mobile App Development final project.

Cipher Courier is a privacy-first mobile messaging app built with Flutter and Firebase. It combines a modern UX with an end-to-end encrypted messaging pipeline based on Signal-style device fanout, local secure key storage, and encrypted media attachments.

## Why This Project Stands Out

- End-to-end encrypted text and image messaging with per-device ciphertext fanout.
- Zero-knowledge backend posture: Firebase stores routing metadata and ciphertext, not plaintext message bodies.
- Security-forward architecture using local key material, trust records, and wake-only notifications.
- Full-stack implementation across Flutter app, Firebase rules, Firestore schema, Storage, and Cloud Functions.

## Current Feature Set

### Authentication and Identity

- Firebase Authentication with Email/Password and Google Sign-In.
- Account registration and login flows with polished UI.
- QR-based account linking to connect peers for secure chat.

### Secure Messaging

- 1:1 secure conversations with deterministic direct conversation IDs.
- Group messaging using encrypted fanout to each member device.
- Signal-style key/session handling with local secure storage.
- Local encrypted message persistence for conversation history.

### Encrypted Media Attachments

- Image encryption on-device before upload.
- Ciphertext stored in Firebase Storage under conversation-scoped paths.
- Encrypted payload metadata carried inside secure message envelope.
- Inline decrypted image previews in chat bubbles.
- Tap-to-open full-screen image viewer with zoom/pan.

### Collaboration and Utility Features

- Group creation and membership management.
- Community forum posting stream.
- Settings for sync behavior and camera preference.
- Realtime inbox updates plus manual sync fallback.

### Backend and Ops

- Cloud Function to send wake-only push notifications when new encrypted device messages arrive.
- Scheduled Cloud Function to clean up expired encrypted attachments.
- Firestore and Storage rules aligned to conversation/group membership.

## Security and Privacy Model

- Message content and image bytes are encrypted client-side before upload.
- Firestore stores ciphertext envelopes and routing metadata only.
- Private keys, sessions, and ratchet state remain on-device.
- Push notifications are data-only wake signals and do not include plaintext.
- Attachment reads/writes are restricted by Storage rules to conversation members.

For full schema documentation, see [docs/firestore_schema.md](docs/firestore_schema.md).

## Tech Stack

- Flutter (Material 3)
- Firebase Core / Auth / Firestore / Storage / Messaging / App Check
- Cloud Functions for Firebase (Node.js 20)
- libsignal_protocol_dart
- flutter_secure_storage + sqflite
- cryptography package (AES-GCM operations for attachments)

## Project Structure

```text
lib/
  auth/            # login/register/auth wrapper and auth service
  chat/            # primary chat UI, groups, forums, settings tabs
  signal/          # Signal protocol services, repositories, local secure store
  services/        # app feature services (forums/groups/local options)
  models/          # bootstrap and shared models
functions/
  index.js         # wake-notification and attachment cleanup functions
docs/
  firestore_schema.md
```

## Quick Start

### 1. Prerequisites

- Flutter SDK (Dart >= 3.10)
- Android Studio / Android device or emulator
- Firebase CLI
- Node.js 20 (for functions)

### 2. Install dependencies

```bash
flutter pub get
cd functions && npm install
```

### 3. Firebase project setup checklist

In Firebase Console for project `claude-md-final` (or your own project):

1. Enable Authentication providers:
   - Email/Password
   - Google
2. Create Firestore database.
3. Set up Firebase Storage by clicking Get Started.
4. Confirm Android app config is downloaded to `android/app/google-services.json`.
5. (Recommended) Configure App Check:
   - Debug provider for local testing.
   - Register your debug token if App Check enforcement is enabled.

### 4. Deploy rules and functions

```bash
firebase deploy --only firestore:rules,firestore:indexes,storage,functions
```

### 5. Run the app

```bash
flutter run
```

## Demo Script for Final Presentation

1. Sign in on two devices/accounts.
2. Link peers using the QR flow.
3. Send encrypted text from Device A to Device B.
4. Send encrypted image from Device A.
5. Show image preview in chat bubble on both sender and receiver.
6. Tap image bubble to open full-screen preview.
7. Create a group, add members, and send a group message.
8. Explain wake-only FCM and ciphertext-only backend storage.

## Developer Commands

```bash
flutter analyze
flutter test
flutter build apk --debug
```

Functions workspace commands:

```bash
cd functions
npm run serve
npm run deploy
npm run logs
```

## Known Notes

- Firebase options are currently configured for Android and Web targets.
- If Storage uploads fail with App Check errors in debug, register the debug token or temporarily relax enforcement for local testing.
- If push wake is unavailable in your environment, manual sync still supports message retrieval.

## Academic Context

This repository is the final deliverable for a Spring 2026 Mobile App Development course, emphasizing secure systems design, full-stack mobile architecture, and production-style engineering practices.
