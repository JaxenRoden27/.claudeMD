# Flutter Module Plan for Privacy-First E2EE Messaging

This plan maps the target architecture onto the current project, which already has:

- [lib/main.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/main.dart)
- [lib/signal/secure_signal_protocol_store.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/secure_signal_protocol_store.dart)
- [lib/signal/signal_service.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_service.dart)
- [lib/signal/signal_message_repository.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_message_repository.dart)
- [lib/signal/signal_fcm_coordinator.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_fcm_coordinator.dart)

## Target `lib/` layout

```text
lib/
  app/
    app.dart
    bootstrap.dart
    routing/
    theme/
  features/
    auth/
      application/
      data/
      presentation/
    devices/
      application/
      data/
      presentation/
    conversations/
      application/
      data/
      presentation/
    messages/
      application/
      data/
      presentation/
    attachments/
      application/
      data/
      presentation/
    groups/
      application/
      data/
      presentation/
    trust/
      application/
      data/
      presentation/
  core/
    crypto/
    secure_storage/
    persistence/
    firebase/
    notifications/
    logging/
    models/
    util/
  signal/
    protocol/
    session/
    repositories/
    sync/
```

## How the current files should evolve

### 1. `secure_signal_protocol_store.dart`

Keep it, but narrow its responsibility to Signal protocol state only.

Move toward:

- `lib/signal/protocol/signal_protocol_store.dart`

Responsibilities:

- identity key pair storage
- signed prekey storage
- one-time prekey private storage
- session record storage
- trusted identity pinning

Do not let it manage:

- Firestore reads/writes
- UI concerns
- decrypted message cache

### 2. `signal_service.dart`

Split it into smaller services.

Recommended decomposition:

- `lib/signal/protocol/prekey_bundle_service.dart`
- `lib/signal/session/session_cipher_service.dart`
- `lib/signal/session/session_establishment_service.dart`
- `lib/signal/session/device_session_registry.dart`

Responsibilities after split:

- X3DH bundle fetch/process
- Double Ratchet encrypt/decrypt
- per-device session lookup
- signed prekey rotation policy

Avoid keeping one large God-service for crypto + Firestore + routing.

### 3. `signal_message_repository.dart`

Replace the current chat-centric store with per-device fanout repositories.

Recommended replacements:

- `lib/features/messages/data/device_message_repository.dart`
- `lib/features/conversations/data/conversation_repository.dart`
- `lib/features/attachments/data/attachment_repository.dart`

Responsibilities:

- create conversation shells
- write one ciphertext record per recipient device
- fetch queued device-targeted ciphertext
- update delivery states

### 4. `signal_fcm_coordinator.dart`

Keep the concept, but make it a wake-and-sync entry point only.

Move toward:

- `lib/core/notifications/push_wakeup_handler.dart`
- `lib/signal/sync/ciphertext_sync_service.dart`

Responsibilities:

- parse data-only FCM payload
- fetch ciphertext from Firestore
- hand ciphertext to local decrypt pipeline
- schedule generic local notification after local processing

Never let it:

- trust FCM payload as message content
- display plaintext from payload
- write decrypted content back to Firebase

## Concrete service boundaries

### `core/crypto/`

- `crypto_service.dart`
- `attachment_crypto_service.dart`
- `key_derivation_service.dart`

Purpose:

- abstract all cryptography behind interfaces
- keep UI and repositories unaware of protocol details

### `core/secure_storage/`

- `secure_key_vault.dart`
- `local_secret_store.dart`

Purpose:

- wrap Android Keystore
- gate access to locally protected secrets

### `core/persistence/`

- `app_database.dart`
- `message_plaintext_store.dart`
- `device_state_store.dart`

Purpose:

- local encrypted database for decrypted messages
- local cache of trust state and device list versions

### `core/firebase/`

- `firestore_paths.dart`
- `firebase_auth_service.dart`
- `firestore_transaction_runner.dart`

Purpose:

- centralize schema paths so collection names do not drift
- keep Firebase-specific code out of domain logic

### `signal/protocol/`

- `identity_key_service.dart`
- `signed_prekey_service.dart`
- `one_time_prekey_service.dart`
- `trusted_identity_service.dart`

Purpose:

- key lifecycle and trust continuity

### `signal/session/`

- `session_establishment_service.dart`
- `session_cipher_service.dart`
- `session_reset_service.dart`
- `skipped_message_key_store.dart`

Purpose:

- X3DH
- Double Ratchet
- replay protection
- out-of-order handling

### `signal/repositories/`

- `public_bundle_repository.dart`
- `prekey_claim_repository.dart`

Purpose:

- read/write only public routing data needed for Signal

### `signal/sync/`

- `ciphertext_sync_service.dart`
- `device_fanout_service.dart`
- `delivery_receipt_service.dart`

Purpose:

- send ciphertext fanout
- receive queued device ciphertext
- update delivery state

## State management boundaries

If you use Riverpod or Bloc, keep providers/cubits at the feature/application layer only.

Recommended boundaries:

- presentation layer reads view models
- application layer executes use cases
- data layer talks to repositories
- crypto layer is injected as an implementation detail

UI should never call:

- `FirebaseFirestore.instance` directly
- `FirebaseMessaging.instance` directly
- `SignalProtocolStore` directly

## Suggested use cases

- `RegisterFirstDevice`
- `UploadPreKeyBatch`
- `FetchRecipientDeviceBundles`
- `SendFirstDeviceMessage`
- `SendRatchetMessage`
- `ReceiveCiphertextForCurrentDevice`
- `DecryptQueuedDeviceMessages`
- `RegisterAdditionalDevice`
- `RevokeDevice`
- `RotateSignedPreKey`
- `HandleIdentityKeyChange`
- `SendEncryptedAttachment`
- `FetchAndDecryptAttachment`
- `CreateGroupEpoch`
- `SendGroupMessage`

## Local storage split

Keep these separate:

- protocol/session secrets
- decrypted message cache
- attachment cache
- trust decisions

Reason:

- easier secure wipe
- safer backup exclusions
- cleaner migration path

## Immediate repo changes to make next

1. Replace current `users/{userId}` and `chats/{chatId}` assumptions with the schema in [docs/firestore_schema.md](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/docs/firestore_schema.md).
2. Refactor [lib/signal/signal_service.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_service.dart) into protocol and session-specific classes.
3. Replace [lib/signal/signal_message_repository.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_message_repository.dart) with per-device message fanout repositories.
4. Update [lib/signal/signal_fcm_coordinator.dart](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/lib/signal/signal_fcm_coordinator.dart) so it fetches ciphertext only for the target device.
5. Introduce a local encrypted DB for decrypted messages and trust state.
6. Add emulator tests for the new rules before shipping.

## Non-negotiable code rules

- Never serialize private keys into Firestore, Storage, Functions payloads, or logs.
- Never put plaintext message bodies or filenames in Firebase.
- Never send one ciphertext blob intended for multiple recipient devices.
- Never let a newly linked device read historical plaintext unless explicit secure history transfer is separately implemented.
- Never trust Firebase Auth alone as proof of cryptographic identity continuity.
