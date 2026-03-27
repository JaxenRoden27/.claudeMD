# Firestore Schema for Privacy-First E2EE Messaging

This schema assumes:

- `FirebaseAuth.uid == app userId`
- all message and attachment content is encrypted on-device before upload
- Firebase is untrusted for confidentiality
- each recipient device gets its own ciphertext record

## Collection overview

```text
users_private/{userId}
public_user_bundles/{userId}
public_user_bundles/{userId}/devices/{deviceId}
public_user_bundles/{userId}/devices/{deviceId}/one_time_prekeys/{preKeyId}
conversations/{conversationId}
conversations/{conversationId}/device_messages/{deliveryId}
conversations/{conversationId}/attachments/{attachmentId}
groups/{groupId}
groups/{groupId}/members/{memberId}
key_audit_events/{eventId}
```

## 1. `users_private/{userId}`

Owner-only account metadata. Do not put anything here that peers need to read.

### Required fields

- `userId: string`
- `createdAt: timestamp`
- `updatedAt: timestamp`
- `accountState: string`
- `discoverability: map`
- `profileCiphertext: string | null`
- `profileVersion: int`

### Plaintext metadata

- account lifecycle flags
- discoverability settings

### Ciphertext fields

- `profileCiphertext`

### Notes

- Never store phone/email in plaintext here unless product policy explicitly accepts that exposure.
- Do not store any private keys here.

## 2. `public_user_bundles/{userId}`

Public, sender-readable user bundle root.

### Required fields

- `userId: string`
- `createdAt: timestamp`
- `updatedAt: timestamp`
- `deviceListVersion: int`
- `identityAuditVersion: int`

### Plaintext metadata

- device list version
- trust audit version

### Notes

- This document is safe to expose to authenticated senders.

## 3. `public_user_bundles/{userId}/devices/{deviceId}`

Per-device public Signal bundle metadata.

### Document ID

- `deviceId`

### Required fields

- `userId: string`
- `deviceId: string`
- `registrationId: int`
- `identityKeyPublic: string`
- `signedPreKey: map`
- `preKeyCount: int`
- `capabilities: map`
- `status: "active" | "revoked" | "inactive"`
- `deviceOrdinal: int`
- `deviceNameCiphertext: string | null`
- `createdAt: timestamp`
- `lastSeenAt: timestamp`
- `updatedAt: timestamp`

### `signedPreKey` fields

- `id: int`
- `publicKey: string`
- `signature: string`
- `createdAt: timestamp`
- `expiresAt: timestamp | null`

### Plaintext metadata

- public identity key
- signed prekey public material
- registration ID
- device status
- prekey stock count

### Ciphertext fields

- `deviceNameCiphertext`

### Notes

- Private identity key and signed prekey private component never leave the device.
- `status == revoked` means stop fanout immediately.

## 4. `public_user_bundles/{userId}/devices/{deviceId}/one_time_prekeys/{preKeyId}`

One-time public prekey inventory for offline first-contact messaging.

### Document ID

- `preKeyId`

### Required fields

- `userId: string`
- `deviceId: string`
- `preKeyId: string`
- `publicKey: string`
- `state: "available" | "claimed"`
- `uploadedAt: timestamp`
- `claimedAt: timestamp | null`
- `claimedByUserIdHash: string | null`

### Plaintext metadata

- public prekey
- claim state

### Notes

- Claim this in a transaction or Cloud Function.
- The server may know a prekey was claimed, but never learns session secrets.

## 5. `conversations/{conversationId}`

Conversation metadata only. No plaintext previews.

### Document ID

- deterministic ID or random ID

### Required fields

- `conversationId: string`
- `type: "direct" | "group"`
- `participantUserIds: string[]`
- `participantSetHash: string`
- `createdBy: string`
- `createdAt: timestamp`
- `latestMessageAt: timestamp`
- `policy: map`
- `groupId: string | null`

### `policy` fields

- `disappearingMessagesSeconds: int | null`
- `allowHistorySync: bool`
- `protocolVersion: int`

### Plaintext metadata

- participant user IDs
- coarse type
- timestamps
- disappearing timer configuration

### Notes

- Do not store `lastMessagePreview`.
- If a title exists for a direct conversation, keep it local or encrypted.

## 6. `conversations/{conversationId}/device_messages/{deliveryId}`

Core per-device ciphertext fanout record.

### Document ID

- random `deliveryId`

### Required fields

- `conversationId: string`
- `messageId: string`
- `senderUserId: string`
- `senderDeviceId: string`
- `recipientUserId: string`
- `recipientDeviceId: string`
- `messageType: string`
- `protocolVersion: int`
- `envelopeCiphertext: string`
- `attachmentRefs: string[]`
- `createdAt: timestamp`
- `expiresAt: timestamp | null`
- `serverOrder: int | null`
- `deliveryState: "queued" | "delivered" | "read" | "expired"`

### Plaintext metadata

- sender user/device IDs
- recipient user/device IDs
- creation timestamp
- expiry timestamp
- protocol version
- coarse message type

### Ciphertext fields

- `envelopeCiphertext`

### Notes

- `envelopeCiphertext` contains the encrypted body and any encrypted attachment key material.
- Each recipient device receives a distinct record.
- This is what prevents newly added devices from automatically seeing old messages.

## 7. `conversations/{conversationId}/attachments/{attachmentId}`

Encrypted attachment metadata only.

### Document ID

- random `attachmentId`

### Required fields

- `conversationId: string`
- `messageId: string`
- `storagePath: string`
- `ciphertextHash: string`
- `sizePadded: int`
- `headerCiphertext: string`
- `createdAt: timestamp`
- `expiresAt: timestamp | null`

### Plaintext metadata

- storage object path
- padded size
- ciphertext hash

### Ciphertext fields

- `headerCiphertext`

### Notes

- attachment filename, media type hint, thumbnail key, and plaintext digest should be encrypted inside `headerCiphertext` or inside the message envelope
- never use the original filename in `storagePath`

## 8. `groups/{groupId}`

Server-visible group shell with encrypted state.

### Required fields

- `groupId: string`
- `createdBy: string`
- `createdAt: timestamp`
- `currentEpoch: int`
- `membershipVersion: int`
- `groupStateCiphertext: string`

### Plaintext metadata

- epoch counter
- membership version

### Ciphertext fields

- `groupStateCiphertext`

## 9. `groups/{groupId}/members/{memberId}`

Group routing membership.

### Document ID

- recommended: `{userId}_{deviceId}`

### Required fields

- `groupId: string`
- `memberId: string`
- `userId: string`
- `deviceId: string`
- `role: "admin" | "member"`
- `state: "active" | "removed"`
- `joinedEpoch: int`
- `removedEpoch: int | null`
- `createdAt: timestamp`

### Plaintext metadata

- user/device routing
- role
- epoch boundaries

### Notes

- removing a member must trigger client-side rekey and new epoch distribution

## 10. `key_audit_events/{eventId}`

Identity continuity and re-registration audit trail.

### Required fields

- `ownerUserId: string`
- `peerUserId: string | null`
- `deviceId: string`
- `eventType: string`
- `oldIdentityKeyHash: string | null`
- `newIdentityKeyHash: string`
- `occurredAt: timestamp`
- `actorUserId: string`

### Plaintext metadata

- event type
- hashed fingerprints
- timing

### Notes

- show these events in trust UI when identity continuity changes

## Forbidden server-side fields

The following fields should never exist anywhere in Firestore:

- `body`
- `text`
- `messageBody`
- `preview`
- `notificationBody`
- `attachmentFilename`
- `plaintextMimeType`
- `decryptedContent`
- `privateKey`
- `sessionKey`
- `chainKey`
- `rootKey`

## Required indexes

See [firestore.indexes.json](/c:/School/Spring%202026/Mobile%20App%20Dev/final_project/.claudeMD/firestore.indexes.json).
