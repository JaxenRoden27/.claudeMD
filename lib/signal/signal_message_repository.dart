import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'local_encrypted_chat_store.dart';
import 'secure_signal_protocol_store.dart';
import 'signal_models.dart';
import 'signal_service.dart';

class SignalMessageRepository {
  SignalMessageRepository({
    required FirebaseFirestore firestore,
    required SignalService signalService,
    required LocalEncryptedChatStore localStore,
    required this.localUserId,
    required this.localDeviceId,
  }) : _firestore = firestore,
       _signalService = signalService,
       _localStore = localStore;

  factory SignalMessageRepository.forLocalDevice({
    required FirebaseFirestore firestore,
    required String localUserId,
    required String localDeviceId,
  }) {
    final namespace = '$localUserId.$localDeviceId';
    final signalStore = SecureSignalProtocolStore(namespace: namespace);
    return SignalMessageRepository(
      firestore: firestore,
      signalService: SignalService(
        firestore: firestore,
        signalStore: signalStore,
      ),
      localStore: LocalEncryptedChatStore(namespace: namespace),
      localUserId: localUserId,
      localDeviceId: localDeviceId,
    );
  }

  final FirebaseFirestore _firestore;
  final SignalService _signalService;
  final LocalEncryptedChatStore _localStore;
  final Random _secureRandom = Random.secure();

  static final AesGcm _attachmentCipher = AesGcm.with256bits();
  static final Sha256 _sha256 = Sha256();
  static const int maxEncryptedImageBytes = 5 * 1024 * 1024;
  static const Duration _attachmentTtl = Duration(days: 7);

  final String localUserId;
  final String localDeviceId;
  StreamSubscription<dynamic>? _realtimeSubscription;
  bool _syncInFlight = false;

  final _inboxUpdatesController = StreamController<void>.broadcast();
  Stream<void> get inboxUpdates => _inboxUpdatesController.stream;

  void dispose() {
    _inboxUpdatesController.close();
    _realtimeSubscription?.cancel();
  }

  Future<void> registerCurrentDevice({String? profileLabel}) {
    return _signalService.registerUserOnInstall(
      userId: localUserId,
      deviceId: localDeviceId,
      profileLabel: profileLabel,
    );
  }

  void setupRealtimeListener() {
    _realtimeSubscription?.cancel();
    // Use the same collectionGroup query as syncPendingMessages but with snaps
    final query = _firestore
        .collectionGroup('device_messages')
        .where('recipientUserId', isEqualTo: localUserId)
        .where('recipientDeviceId', isEqualTo: localDeviceId)
        .where('deliveryState', isEqualTo: 'queued');

    _realtimeSubscription = query.snapshots().listen((snap) {
      if (snap.docs.isNotEmpty && !_syncInFlight) {
        // Avoid overlapping sync runs and swallow listener-scope failures.
        _syncInFlight = true;
        unawaited(() async {
          try {
            await syncPendingMessages();
          } catch (_) {
            // No-op: listener wakes sync opportunistically.
          } finally {
            _syncInFlight = false;
          }
        }());
      }
    });
  }

  Future<void> updateRoutingToken({
    required String fcmToken,
    required String platform,
  }) {
    return _signalService.updateDeviceRoutingToken(
      userId: localUserId,
      deviceId: localDeviceId,
      fcmToken: fcmToken,
      platform: platform,
    );
  }

  static String directConversationId(String userA, String userB) {
    final sorted = <String>[userA, userB]..sort();
    return 'direct_${sorted.join('__')}';
  }

  Future<String> ensureDirectConversation({required String peerUserId}) async {
    final conversationId = directConversationId(localUserId, peerUserId);
    final conversationRef = _firestore
        .collection('conversations')
        .doc(conversationId);
    final existing = await conversationRef.get();
    if (!existing.exists) {
      await conversationRef.set(<String, dynamic>{
        'conversationId': conversationId,
        'type': 'direct',
        'participantUserIds': <String>[localUserId, peerUserId]..sort(),
        'participantSetHash': conversationId,
        'createdBy': localUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'latestMessageAt': FieldValue.serverTimestamp(),
        'policy': <String, dynamic>{
          'disappearingMessagesSeconds': null,
          'allowHistorySync': false,
          'protocolVersion': 1,
        },
        'groupId': null,
      });
    }
    return conversationId;
  }

  Future<String> ensureGroupConversation({
    required String groupId,
    required List<String> memberUserIds,
  }) async {
    final participants = <String>{
      localUserId,
      ...memberUserIds,
    }.where((id) => id.trim().isNotEmpty).toList(growable: false)..sort();
    if (participants.length < 2) {
      throw StateError(
        'Group conversations require at least two participants.',
      );
    }

    final conversationId = 'group_$groupId';
    final conversationRef = _firestore
        .collection('conversations')
        .doc(conversationId);
    final existing = await conversationRef.get();
    if (!existing.exists) {
      await conversationRef.set(<String, dynamic>{
        'conversationId': conversationId,
        'type': 'group',
        'participantUserIds': participants,
        'participantSetHash': conversationId,
        'createdBy': localUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'latestMessageAt': FieldValue.serverTimestamp(),
        'policy': <String, dynamic>{
          'disappearingMessagesSeconds': null,
          'allowHistorySync': false,
          'protocolVersion': 1,
        },
        'groupId': groupId,
      });
    }
    return conversationId;
  }

  Future<void> sendTextMessage({
    required String peerUserId,
    required String plaintext,
  }) async {
    try {
      final conversationId = await _runStep(
        'ensure direct conversation',
        () => ensureDirectConversation(peerUserId: peerUserId),
      );
      final messageId = _firestore.collection('_message_ids').doc().id;
      await _sendFanoutMessage(
        conversationId: conversationId,
        messageId: messageId,
        plaintext: plaintext,
        messageType: 'text',
        recipientUserIds: <String>[peerUserId],
      );

      _inboxUpdatesController.add(null);
    } on StateError {
      rethrow;
    } on FirebaseException catch (error) {
      throw StateError(
        'sendTextMessage failed with Firestore ${error.code}: ${error.message ?? error}',
      );
    } catch (error) {
      throw StateError('sendTextMessage failed: $error');
    }
  }

  Future<void> sendGroupTextMessage({
    required String groupId,
    required List<String> memberUserIds,
    required String plaintext,
  }) async {
    final conversationId = await ensureGroupConversation(
      groupId: groupId,
      memberUserIds: memberUserIds,
    );
    final messageId = _firestore.collection('_message_ids').doc().id;
    await _sendFanoutMessage(
      conversationId: conversationId,
      messageId: messageId,
      plaintext: plaintext,
      messageType: 'text',
      recipientUserIds: memberUserIds,
    );
    _inboxUpdatesController.add(null);
  }

  Future<void> sendEncryptedImageMessage({
    required String peerUserId,
    required Uint8List imageBytes,
    required String mimeType,
    String Function(String payload)? wrapPlaintext,
  }) async {
    if (imageBytes.isEmpty) {
      throw StateError('Image payload is empty.');
    }
    if (imageBytes.length > maxEncryptedImageBytes) {
      throw StateError('Image exceeds 5 MB limit after preprocessing.');
    }

    final conversationId = await ensureDirectConversation(
      peerUserId: peerUserId,
    );
    final messageId = _firestore.collection('_message_ids').doc().id;

    final attachment = await _createEncryptedAttachment(
      conversationId: conversationId,
      messageId: messageId,
      imageBytes: imageBytes,
      mimeType: mimeType,
    );

    final payload = SecureImageAttachmentPayload(
      attachmentId: attachment.attachmentId,
      conversationId: conversationId,
      storagePath: attachment.storagePath,
      mimeType: mimeType,
      fileKeyBase64: attachment.fileKeyBase64,
      fileNonceBase64: attachment.fileNonceBase64,
      fileMacBase64: attachment.fileMacBase64,
      ciphertextHash: attachment.ciphertextHash,
      sizePadded: attachment.sizePadded,
    );

    final securePlaintext = payload.toPlaintextPayload();

    await _sendFanoutMessage(
      conversationId: conversationId,
      messageId: messageId,
      plaintext: wrapPlaintext == null
          ? securePlaintext
          : wrapPlaintext(securePlaintext),
      messageType: 'image',
      recipientUserIds: <String>[peerUserId],
      attachmentRefs: <String>[attachment.attachmentId],
    );
    _inboxUpdatesController.add(null);
  }

  Future<void> sendGroupEncryptedImageMessage({
    required String groupId,
    required List<String> memberUserIds,
    required Uint8List imageBytes,
    required String mimeType,
    String? envelopePrefix,
    String? envelopeSuffix,
  }) async {
    if (imageBytes.isEmpty) {
      throw StateError('Image payload is empty.');
    }
    if (imageBytes.length > maxEncryptedImageBytes) {
      throw StateError('Image exceeds 5 MB limit after preprocessing.');
    }

    final conversationId = await ensureGroupConversation(
      groupId: groupId,
      memberUserIds: memberUserIds,
    );
    final messageId = _firestore.collection('_message_ids').doc().id;

    final attachment = await _createEncryptedAttachment(
      conversationId: conversationId,
      messageId: messageId,
      imageBytes: imageBytes,
      mimeType: mimeType,
    );

    final payload = SecureImageAttachmentPayload(
      attachmentId: attachment.attachmentId,
      conversationId: conversationId,
      storagePath: attachment.storagePath,
      mimeType: mimeType,
      fileKeyBase64: attachment.fileKeyBase64,
      fileNonceBase64: attachment.fileNonceBase64,
      fileMacBase64: attachment.fileMacBase64,
      ciphertextHash: attachment.ciphertextHash,
      sizePadded: attachment.sizePadded,
    );

    final encodedPayload = payload.toPlaintextPayload();
    final plaintext =
        '${envelopePrefix ?? ''}$encodedPayload${envelopeSuffix ?? ''}';

    await _sendFanoutMessage(
      conversationId: conversationId,
      messageId: messageId,
      plaintext: plaintext,
      messageType: 'image',
      recipientUserIds: memberUserIds,
      attachmentRefs: <String>[attachment.attachmentId],
    );
    _inboxUpdatesController.add(null);
  }

  Future<Uint8List> decryptAttachmentPayload(
    SecureImageAttachmentPayload payload,
    Uint8List ciphertextBytes,
  ) async {
    final ciphertextHash = await _sha256.hash(ciphertextBytes);
    if (base64Encode(ciphertextHash.bytes) != payload.ciphertextHash) {
      throw StateError('Attachment ciphertext hash mismatch.');
    }

    if (ciphertextBytes.length < 28) {
      throw StateError('Attachment ciphertext is malformed.');
    }

    final keyBytes = base64Decode(payload.fileKeyBase64);
    final nonce = base64Decode(payload.fileNonceBase64);
    final macBytes = base64Decode(payload.fileMacBase64);
    final cipherText = ciphertextBytes.sublist(28);

    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    return Uint8List.fromList(
      await _attachmentCipher.decrypt(box, secretKey: SecretKey(keyBytes)),
    );
  }

  Future<Uint8List> downloadAndDecryptAttachment(
    SecureImageAttachmentPayload payload,
  ) async {
    final expectedMaxBytes = max(
      payload.sizePadded + 1024,
      maxEncryptedImageBytes + 1024,
    );
    final ciphertextBytes = await _downloadCiphertextWithBucketFallback(
      storagePath: payload.storagePath,
      expectedMaxBytes: expectedMaxBytes,
    );
    return decryptAttachmentPayload(payload, ciphertextBytes);
  }

  Future<int> syncPendingMessages({String? peerUserId}) async {
    try {
      final targetConversationId = peerUserId == null
          ? null
          : directConversationId(localUserId, peerUserId);

      final snap = await _runStep(
        targetConversationId == null
            ? 'query pending device messages'
            : 'query pending device messages for $targetConversationId',
        () => _loadPendingDeliverySnapshot(
          targetConversationId: targetConversationId,
        ),
      );

      var imported = 0;
      for (final doc in snap.docs) {
        final record = SignalDeliveryRecord.fromFirestore(doc.id, doc.data());

        try {
          final inserted = await _runStep(
            'decrypt delivery ${record.deliveryId}',
            () => _storeInboundRecord(record),
          );
          if (inserted) {
            imported++;
          }

          if (record.deliveryState == 'queued') {
            await _runStep(
              'mark delivery ${record.deliveryId} as delivered',
              () => doc.reference.update(<String, dynamic>{
                'deliveryState': 'delivered',
              }),
            );
          }
        } catch (e) {
          // If decryption completely fails (e.g. InvalidKeyIdException due to stale emulator data),
          // mark it as failed so it stops crashing the sync loop and causing a poison pill.
          if (record.deliveryState == 'queued') {
            await _runStep(
              'mark delivery ${record.deliveryId} as failed',
              () => doc.reference.update(<String, dynamic>{
                'deliveryState': 'failed',
              }),
            );
          }
        }
      }

      return imported;
    } on StateError {
      rethrow;
    } on FirebaseException catch (error) {
      throw StateError(
        'syncPendingMessages failed with Firestore ${error.code}: ${error.message ?? error}',
      );
    } catch (error) {
      throw StateError('syncPendingMessages failed: $error');
    }
  }

  Future<LocalChatMessage?> syncSingleDelivery({
    required String conversationId,
    required String deliveryId,
  }) async {
    final snap = await _firestore
        .collection('conversations')
        .doc(conversationId)
        .collection('device_messages')
        .doc(deliveryId)
        .get();
    final data = snap.data();
    if (data == null) {
      return null;
    }

    final record = SignalDeliveryRecord.fromFirestore(deliveryId, data);
    if (record.recipientUserId != localUserId ||
        record.recipientDeviceId != localDeviceId) {
      return null;
    }

    bool inserted = false;
    try {
      inserted = await _storeInboundRecord(record);
      if (inserted && record.deliveryState == 'queued') {
        await snap.reference.update(<String, dynamic>{
          'deliveryState': 'delivered',
        });
      }
    } catch (e) {
      if (record.deliveryState == 'queued') {
        await snap.reference.update(<String, dynamic>{
          'deliveryState': 'failed',
        });
      }
      return null;
    }

    final messages = await _localStore.loadConversationMessages(conversationId);
    if (messages.isEmpty) {
      return null;
    }
    return messages.last;
  }

  Future<List<LocalChatMessage>> loadConversationMessages({
    required String peerUserId,
  }) {
    return _localStore.loadConversationMessages(
      directConversationId(localUserId, peerUserId),
    );
  }

  Future<List<LocalChatMessage>> loadConversationMessagesByConversationId({
    required String conversationId,
  }) {
    return _localStore.loadConversationMessages(conversationId);
  }

  Future<List<LocalTrustRecord>> loadTrustState({required String peerUserId}) {
    return _localStore.loadTrustRecordsForUser(peerUserId);
  }

  Future<List<LocalTrustRecord>> loadAllKnownPeers() {
    return _localStore.loadAllKnownPeers();
  }

  Future<void> ensurePeerTrust({
    required String peerUserId,
    required String label,
  }) async {
    final bundles = await _signalService.fetchActiveDeviceBundles(
      userId: peerUserId,
    );
    for (final bundle in bundles) {
      await _localStore.upsertTrustRecord(
        userId: bundle.userId,
        deviceId: bundle.deviceId,
        identityKeyHash: await _signalService.identityKeyDigest(
          bundle.identityKeyPublicBase64,
        ),
        label: label,
      );
    }
  }

  Future<bool> _storeInboundRecord(SignalDeliveryRecord record) async {
    if (await _localStore.hasDelivery(record.deliveryId)) {
      return false;
    }

    final senderBundle = await _signalService.fetchDeviceBundle(
      userId: record.senderUserId,
      deviceId: record.senderDeviceId,
    );
    await _recordTrustForBundles(<SignalDeviceBundle>[senderBundle]);

    final plaintext = await _signalService.decryptEnvelope(
      senderUserId: record.senderUserId,
      senderDeviceId: record.senderDeviceId,
      envelope: record.envelope,
    );

    await _localStore.upsertMessage(
      LocalChatMessage(
        localId: null,
        deliveryId: record.deliveryId,
        conversationId: record.conversationId,
        messageId: record.messageId,
        senderUserId: record.senderUserId,
        senderDeviceId: record.senderDeviceId,
        recipientUserId: record.recipientUserId,
        recipientDeviceId: record.recipientDeviceId,
        plaintext: plaintext,
        createdAt: record.createdAt,
        outgoing: false,
        deliveryState: 'delivered',
      ),
    );

    _inboxUpdatesController.add(null);
    return true;
  }

  Future<void> _sendFanoutMessage({
    required String conversationId,
    required String messageId,
    required String plaintext,
    required String messageType,
    required List<String> recipientUserIds,
    List<String> attachmentRefs = const <String>[],
  }) async {
    final recipients =
        recipientUserIds
            .where((userId) => userId != localUserId)
            .toSet()
            .toList(growable: false)
          ..sort();
    if (recipients.isEmpty) {
      throw StateError('No valid recipients were provided.');
    }

    final batch = _firestore.batch();
    String? localRecipientUserId;
    String? localRecipientDeviceId;

    for (final recipientUserId in recipients) {
      final recipientBundles = await _runStep(
        'load recipient devices',
        () => _signalService.fetchActiveDeviceBundles(userId: recipientUserId),
      );
      if (recipientBundles.isEmpty) {
        throw StateError(
          'Recipient $recipientUserId has no active devices in public_user_bundles.',
        );
      }

      await _runStep(
        'record peer trust snapshot',
        () => _recordTrustForBundles(recipientBundles),
      );

      for (final bundle in recipientBundles) {
        final envelope = await _runStep(
          'encrypt for ${bundle.userId}/${bundle.deviceId}',
          () => _signalService.encryptMessageForDevice(
            senderUserId: localUserId,
            recipientUserId: recipientUserId,
            recipientDeviceId: bundle.deviceId,
            plaintext: plaintext,
          ),
        );

        final deliveryRef = _firestore
            .collection('conversations')
            .doc(conversationId)
            .collection('device_messages')
            .doc();

        final deliveryRecord = SignalDeliveryRecord(
          deliveryId: deliveryRef.id,
          conversationId: conversationId,
          messageId: messageId,
          senderUserId: localUserId,
          senderDeviceId: localDeviceId,
          recipientUserId: recipientUserId,
          recipientDeviceId: bundle.deviceId,
          messageType: messageType,
          protocolVersion: 1,
          envelope: envelope,
          createdAt: DateTime.now(),
          deliveryState: 'queued',
          attachmentRefs: attachmentRefs,
        );

        batch.set(deliveryRef, deliveryRecord.toFirestore());
        localRecipientUserId ??= recipientUserId;
        localRecipientDeviceId ??= bundle.deviceId;
      }
    }

    batch.set(
      _firestore.collection('conversations').doc(conversationId),
      <String, dynamic>{'latestMessageAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );

    await _runStep('commit encrypted device fanout', batch.commit);

    await _runStep(
      'cache local outgoing plaintext',
      () => _localStore.upsertMessage(
        LocalChatMessage(
          localId: null,
          deliveryId: 'local_$messageId',
          conversationId: conversationId,
          messageId: messageId,
          senderUserId: localUserId,
          senderDeviceId: localDeviceId,
          recipientUserId: localRecipientUserId ?? recipients.first,
          recipientDeviceId: localRecipientDeviceId ?? localDeviceId,
          plaintext: plaintext,
          createdAt: DateTime.now(),
          outgoing: true,
          deliveryState: 'sent',
        ),
      ),
    );
  }

  Future<_EncryptedAttachmentUpload> _createEncryptedAttachment({
    required String conversationId,
    required String messageId,
    required Uint8List imageBytes,
    required String mimeType,
  }) async {
    final attachmentRef = _firestore
        .collection('conversations')
        .doc(conversationId)
        .collection('attachments')
        .doc();
    final attachmentId = attachmentRef.id;
    final storagePath = 'attachments/$conversationId/$messageId/$attachmentId';

    final keyBytes = _randomBytes(32);
    final fileNonce = _randomBytes(12);
    final fileBox = await _attachmentCipher.encrypt(
      imageBytes,
      secretKey: SecretKey(keyBytes),
      nonce: fileNonce,
    );

    final ciphertextBytes = Uint8List.fromList(<int>[
      ...fileNonce,
      ...fileBox.mac.bytes,
      ...fileBox.cipherText,
    ]);
    final digest = await _sha256.hash(ciphertextBytes);
    final ciphertextHash = base64Encode(digest.bytes);

    final headerNonce = _randomBytes(12);
    final headerPayload = jsonEncode(<String, dynamic>{
      'mimeType': mimeType,
      'plaintextSize': imageBytes.length,
    });
    final headerBox = await _attachmentCipher.encrypt(
      utf8.encode(headerPayload),
      secretKey: SecretKey(keyBytes),
      nonce: headerNonce,
    );
    final headerCiphertext = jsonEncode(<String, String>{
      'nonce': base64Encode(headerBox.nonce),
      'ciphertext': base64Encode(headerBox.cipherText),
      'mac': base64Encode(headerBox.mac.bytes),
    });

    await _uploadCiphertextWithBucketFallback(
      storagePath: storagePath,
      ciphertextBytes: ciphertextBytes,
    );

    await attachmentRef.set(<String, dynamic>{
      'conversationId': conversationId,
      'messageId': messageId,
      'storagePath': storagePath,
      'ciphertextHash': ciphertextHash,
      'sizePadded': _padTo4KiB(imageBytes.length),
      'headerCiphertext': headerCiphertext,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(_attachmentTtl)),
    });

    return _EncryptedAttachmentUpload(
      attachmentId: attachmentId,
      storagePath: storagePath,
      ciphertextHash: ciphertextHash,
      sizePadded: _padTo4KiB(imageBytes.length),
      fileKeyBase64: base64Encode(keyBytes),
      fileNonceBase64: base64Encode(fileBox.nonce),
      fileMacBase64: base64Encode(fileBox.mac.bytes),
    );
  }

  Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _secureRandom.nextInt(256)),
    );
  }

  Future<void> _uploadCiphertextWithBucketFallback({
    required String storagePath,
    required Uint8List ciphertextBytes,
  }) async {
    final metadata = SettableMetadata(
      contentType: 'application/octet-stream',
      customMetadata: <String, String>{'enc': 'aes-gcm-256', 'v': '1'},
    );

    Object? lastError;

    final candidateInstances = _buildPreferredStorageInstances();

    for (final storage in candidateInstances) {
      try {
        final ref = storage.ref(storagePath);
        try {
          await ref.putData(ciphertextBytes, metadata);
        } on FirebaseException catch (error) {
          if (!_isResumableSessionFailure(error)) {
            rethrow;
          }
          // Some Android SDK sessions fail immediately with 404 on resumable endpoints.
          // Retry as a single-request base64 upload on the same object reference.
          await ref.putString(
            base64Encode(ciphertextBytes),
            format: PutStringFormat.base64,
            metadata: metadata,
          );
        }
        return;
      } on FirebaseException catch (error) {
        lastError = error;
        if (!_shouldTryAnotherBucket(error)) {
          rethrow;
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw StateError(
      'Attachment upload failed before contacting Firebase Storage.',
    );
  }

  Future<Uint8List> _downloadCiphertextWithBucketFallback({
    required String storagePath,
    required int expectedMaxBytes,
  }) async {
    Object? lastError;
    final candidateInstances = _buildPreferredStorageInstances();

    for (final storage in candidateInstances) {
      try {
        final bytes = await storage.ref(storagePath).getData(expectedMaxBytes);
        if (bytes == null || bytes.isEmpty) {
          throw StateError('Downloaded attachment is empty for $storagePath.');
        }
        return bytes;
      } on FirebaseException catch (error) {
        lastError = error;
        if (!_shouldTryAnotherBucket(error)) {
          rethrow;
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw StateError(
      'Attachment download failed before contacting Firebase Storage.',
    );
  }

  List<FirebaseStorage> _buildPreferredStorageInstances() {
    final app = Firebase.app();
    final configuredBucket = (app.options.storageBucket ?? '').trim();
    final projectId = app.options.projectId.trim();

    String stripGsPrefix(String bucket) {
      return bucket.startsWith('gs://') ? bucket.substring(5) : bucket;
    }

    final canonicalCandidates = <String>{
      if (configuredBucket.isNotEmpty) stripGsPrefix(configuredBucket),
      if (projectId.isNotEmpty) '$projectId.appspot.com',
      if (projectId.isNotEmpty) '$projectId.firebasestorage.app',
    };

    final instances = <FirebaseStorage>[FirebaseStorage.instance];
    for (final bucket in canonicalCandidates) {
      if (bucket.isEmpty) {
        continue;
      }
      try {
        instances.add(
          FirebaseStorage.instanceFor(app: app, bucket: 'gs://$bucket'),
        );
      } catch (_) {
        // Keep falling back to other candidates.
      }
      try {
        instances.add(FirebaseStorage.instanceFor(app: app, bucket: bucket));
      } catch (_) {
        // Keep falling back to other candidates.
      }
    }

    final deduped = <FirebaseStorage>[];
    final seen = <String>{};
    for (final storage in instances) {
      final key = '${storage.app.name}|${storage.bucket}';
      if (seen.add(key)) {
        deduped.add(storage);
      }
    }
    return deduped;
  }

  bool _shouldTryAnotherBucket(FirebaseException error) {
    final code = error.code.toLowerCase();
    final message = (error.message ?? '').toLowerCase();
    return code.contains('object-not-found') ||
        code.contains('unknown') ||
        code.contains('canceled') ||
        code.contains('cancelled') ||
        code.contains('retry-limit-exceeded') ||
        message.contains('object does not exist') ||
        message.contains('not found') ||
        message.contains('terminated the upload session') ||
        message.contains('operation was cancelled') ||
        message.contains('operation was canceled');
  }

  bool _isResumableSessionFailure(FirebaseException error) {
    final code = error.code.toLowerCase();
    final message = (error.message ?? '').toLowerCase();
    return code.contains('object-not-found') ||
        code.contains('canceled') ||
        code.contains('cancelled') ||
        message.contains('terminated the upload session') ||
        message.contains('object does not exist at location') ||
        message.contains('not found');
  }

  int _padTo4KiB(int size) => ((size + 4095) ~/ 4096) * 4096;

  Future<void> _recordTrustForBundles(List<SignalDeviceBundle> bundles) async {
    for (final bundle in bundles) {
      await _localStore.upsertTrustRecord(
        userId: bundle.userId,
        deviceId: bundle.deviceId,
        identityKeyHash: await _signalService.identityKeyDigest(
          bundle.identityKeyPublicBase64,
        ),
      );
    }
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _loadPendingDeliverySnapshot({
    String? targetConversationId,
  }) {
    if (targetConversationId != null) {
      return _firestore
          .collection('conversations')
          .doc(targetConversationId)
          .collection('device_messages')
          .where('recipientUserId', isEqualTo: localUserId)
          .where('recipientDeviceId', isEqualTo: localDeviceId)
          .orderBy('createdAt')
          .get();
    }

    return _firestore
        .collectionGroup('device_messages')
        .where('recipientUserId', isEqualTo: localUserId)
        .where('recipientDeviceId', isEqualTo: localDeviceId)
        .orderBy('createdAt')
        .get();
  }

  Future<T> _runStep<T>(String label, Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseException catch (error) {
      throw StateError(
        '$label failed with Firestore ${error.code}: ${error.message ?? error}',
      );
    } catch (error) {
      throw StateError('$label failed: $error');
    }
  }
}

class _EncryptedAttachmentUpload {
  const _EncryptedAttachmentUpload({
    required this.attachmentId,
    required this.storagePath,
    required this.ciphertextHash,
    required this.sizePadded,
    required this.fileKeyBase64,
    required this.fileNonceBase64,
    required this.fileMacBase64,
  });

  final String attachmentId;
  final String storagePath;
  final String ciphertextHash;
  final int sizePadded;
  final String fileKeyBase64;
  final String fileNonceBase64;
  final String fileMacBase64;
}
