import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

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
  })  : _firestore = firestore,
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

  final String localUserId;
  final String localDeviceId;

  final _inboxUpdatesController = StreamController<void>.broadcast();
  Stream<void> get inboxUpdates => _inboxUpdatesController.stream;

  void dispose() {
    _inboxUpdatesController.close();
  }

  Future<void> registerCurrentDevice({String? profileLabel}) {
    return _signalService.registerUserOnInstall(
      userId: localUserId,
      deviceId: localDeviceId,
      profileLabel: profileLabel,
    );
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

  Future<String> ensureDirectConversation({
    required String peerUserId,
  }) async {
    final conversationId = directConversationId(localUserId, peerUserId);
    final conversationRef = _firestore.collection('conversations').doc(conversationId);
    final existing = await conversationRef.get();
    if (!existing.exists) {
      await conversationRef.set(
        <String, dynamic>{
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
        },
      );
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
      final recipientBundles = await _runStep(
        'load recipient devices',
        () => _signalService.fetchActiveDeviceBundles(userId: peerUserId),
      );
      if (recipientBundles.isEmpty) {
        throw StateError(
          'The recipient has no active devices registered in public_user_bundles.',
        );
      }

      await _runStep(
        'record peer trust snapshot',
        () => _recordTrustForBundles(recipientBundles),
      );

      final messageId = _firestore.collection('_message_ids').doc().id;
      final batch = _firestore.batch();

      for (final bundle in recipientBundles) {
        final envelope = await _runStep(
          'encrypt for ${bundle.userId}/${bundle.deviceId}',
          () => _signalService.encryptMessageForDevice(
            senderUserId: localUserId,
            recipientUserId: peerUserId,
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
          recipientUserId: peerUserId,
          recipientDeviceId: bundle.deviceId,
          messageType: 'text',
          protocolVersion: 1,
          envelope: envelope,
          createdAt: DateTime.now(),
          deliveryState: 'queued',
        );

        batch.set(deliveryRef, deliveryRecord.toFirestore());
      }

      batch.set(
        _firestore.collection('conversations').doc(conversationId),
        <String, dynamic>{
          'latestMessageAt': FieldValue.serverTimestamp(),
        },
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
            recipientUserId: peerUserId,
            recipientDeviceId: recipientBundles.first.deviceId,
            plaintext: plaintext,
            createdAt: DateTime.now(),
            outgoing: true,
            deliveryState: 'sent',
          ),
        ),
      );
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
        await snap.reference.update(<String, dynamic>{'deliveryState': 'delivered'});
      }
    } catch (e) {
      if (record.deliveryState == 'queued') {
        await snap.reference.update(<String, dynamic>{'deliveryState': 'failed'});
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

  Future<List<LocalTrustRecord>> loadTrustState({
    required String peerUserId,
  }) {
    return _localStore.loadTrustRecordsForUser(peerUserId);
  }

  Future<List<LocalTrustRecord>> loadAllKnownPeers() {
    return _localStore.loadAllKnownPeers();
  }

  Future<void> ensurePeerTrust({
    required String peerUserId,
    required String label,
  }) async {
    final bundles = await _signalService.fetchActiveDeviceBundles(userId: peerUserId);
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

  Future<T> _runStep<T>(
    String label,
    Future<T> Function() action,
  ) async {
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
