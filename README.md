# claude_md_final

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Signal E2EE Integration (1-on-1)

This project now includes a Signal Protocol integration suitable for WhatsApp-style
1-on-1 E2EE with a zero-knowledge Firestore backend.

### Added files

- `lib/signal/secure_signal_protocol_store.dart`
- `lib/signal/signal_service.dart`
- `lib/signal/signal_message_repository.dart`
- `lib/signal/signal_fcm_coordinator.dart`

### Security model

- Firestore stores only public keys and ciphertext.
- Private keys, sessions, prekeys, and ratchet state stay on-device in
	`flutter_secure_storage`.
- FCM is data-only and only wakes the app to fetch/decrypt locally.

### Firestore schema used

- `users/{userId}`
	- `signal.registrationId`
	- `signal.deviceId`
	- `signal.identityKey`
	- `signal.signedPreKey.{id,publicKey,signature,timestamp}`
- `users/{userId}/preKeys/{preKeyId}`
	- `preKeyId`
	- `publicKey`
	- `used`
- `chats/{chatId}`
	- `lastSequence`
- `chats/{chatId}/messages/{messageId}`
	- `sequence`
	- `senderId`
	- `recipientId`
	- `senderDeviceId`
	- `type`
	- `ciphertext`
	- `createdAt`

### Message ordering requirement

Messages are written with a transaction-assigned `sequence` and read using
`orderBy('sequence').orderBy('createdAt')` so the Double Ratchet never processes
messages out of order.

### Startup wiring

- Firebase initializes with `DefaultFirebaseOptions.currentPlatform`.
- Background handler is registered with:
	`FirebaseMessaging.onBackgroundMessage(signalFcmBackgroundHandler)`.
- A bootstrap page in `lib/main.dart` shows:
	1. local key registration
	2. first message encryption/send flow

### Data-only FCM payload contract

```
{
	"chatId": "chat_abc",
	"messageId": "firestore_message_doc_id",
	"localUserId": "current_device_user"
}
```

No plaintext should be included in push payloads.

## Current app architecture

The app now uses:

- Firebase Auth email/password demo accounts for Alice and Bob
- `users_private/{userId}` for private account metadata
- `users_private/{userId}/device_routing/{deviceId}` for FCM routing tokens
- `public_user_bundles/{userId}/devices/{deviceId}` for public Signal bundles
- `conversations/{conversationId}/device_messages/{deliveryId}` for per-device ciphertext fanout
- a local encrypted SQLite transcript store for decrypted messages and trust state

### Key files

- `lib/signal/signal_service.dart`
- `lib/signal/signal_message_repository.dart`
- `lib/signal/signal_fcm_coordinator.dart`
- `lib/signal/local_encrypted_chat_store.dart`
- `functions/index.js`

## Running the secure messaging demo

### App setup

1. Run `flutter pub get`
2. If using Cloud Functions wake fanout, run `npm install` inside `functions/`
3. Deploy or emulate:
   - Firestore rules and indexes
   - Storage rules
   - Functions
4. Enable Email/Password sign-in in Firebase Authentication
5. Start the Flutter app on Android for the most complete test path

### In-app test flow

1. Tap `Provision Both`
2. With `Alice` selected, send a message to Bob
3. Switch to `Bob`
4. Tap `Sync Inbox` if FCM wake is unavailable in your environment
5. Verify the message appears in Bob's local decrypted transcript
6. Send a reply from Bob and switch back to Alice

### Wake-only FCM path

The backend function `sendWakeSignalOnDeviceMessage` watches:

- `conversations/{conversationId}/device_messages/{deliveryId}`

It reads the recipient device's routing token from:

- `users_private/{recipientUserId}/device_routing/{recipientDeviceId}`

Then it sends a data-only FCM wake payload with:

- `type`
- `conversationId`
- `deliveryId`
- `recipientUserId`
- `recipientDeviceId`

No plaintext is included in the push payload.

## Remaining deployment notes

- For production, pair this with Firebase Auth and matching Firestore rules enforcement.
- For local/manual testing, the app can still function with the `Sync Inbox` button even when FCM delivery is unavailable.
- Background delivery depends on valid Android/iOS Firebase Messaging setup and deployed backend Functions.
