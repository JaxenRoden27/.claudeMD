import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'secure_signal_protocol_store.dart';
import 'signal_models.dart';

class SignalService {
  SignalService({
    required FirebaseFirestore firestore,
    required SecureSignalProtocolStore signalStore,
  })  : _firestore = firestore,
        _signalStore = signalStore;

  final FirebaseFirestore _firestore;
  final SecureSignalProtocolStore _signalStore;

  SecureSignalProtocolStore get signalStore => _signalStore;

  static const String defaultDeviceId = '1';
  static const int defaultSignedPreKeyId = 1;

  CollectionReference<Map<String, dynamic>> get _usersPrivate =>
      _firestore.collection('users_private');
  CollectionReference<Map<String, dynamic>> get _publicBundles =>
      _firestore.collection('public_user_bundles');

  DocumentReference<Map<String, dynamic>> _deviceRoutingRef(
    String userId,
    String deviceId,
  ) {
    return _usersPrivate.doc(userId).collection('device_routing').doc(deviceId);
  }

  DocumentReference<Map<String, dynamic>> _deviceRef(
    String userId,
    String deviceId,
  ) {
    return _publicBundles.doc(userId).collection('devices').doc(deviceId);
  }

  CollectionReference<Map<String, dynamic>> _preKeysRef(
    String userId,
    String deviceId,
  ) {
    return _deviceRef(userId, deviceId).collection('one_time_prekeys');
  }

  Future<void> registerUserOnInstall({
    required String userId,
    String deviceId = defaultDeviceId,
    int preKeyStartId = 1,
    int preKeyBatchCount = 100,
    String? profileLabel,
  }) async {
    late final IdentityKeyPair identityKeyPair;
    late final int registrationId;
    late final List<PreKeyRecord> preKeys;
    late final SignedPreKeyRecord signedPreKey;

    final hasLocalIdentity = await _signalStore.hasLocalIdentityMaterial();
    final storedSignedPreKeys = await _signalStore.loadSignedPreKeys();
    final storedPreKeys = await _signalStore.loadPreKeys();

    if (hasLocalIdentity &&
        storedSignedPreKeys.isNotEmpty &&
        storedPreKeys.isNotEmpty) {
      identityKeyPair = await _signalStore.getIdentityKeyPair();
      registrationId = await _signalStore.getLocalRegistrationId();
      signedPreKey = storedSignedPreKeys.first;
      preKeys = storedPreKeys;
    } else {
      identityKeyPair = generateIdentityKeyPair();
      registrationId = generateRegistrationId(false);
      preKeys = generatePreKeys(preKeyStartId, preKeyBatchCount);
      signedPreKey = generateSignedPreKey(
        identityKeyPair,
        defaultSignedPreKeyId,
      );

      await _signalStore.setLocalIdentityMaterial(
        identityKeyPair: identityKeyPair,
        registrationId: registrationId,
      );

      for (final preKey in preKeys) {
        await _signalStore.storePreKey(preKey.id, preKey);
      }
      await _signalStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
    }

    final batch = _firestore.batch();
    batch.set(
      _usersPrivate.doc(userId),
      <String, dynamic>{
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'accountState': 'active',
        'discoverability': <String, dynamic>{'byUserId': true},
        'profileCiphertext': null,
        'profileVersion': 1,
      },
      SetOptions(merge: true),
    );

    batch.set(
      _publicBundles.doc(userId),
      <String, dynamic>{
        'userId': userId,
        'label': (profileLabel?.trim().isNotEmpty ?? false)
            ? profileLabel!.trim()
            : userId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'deviceListVersion': 1,
        'identityAuditVersion': 1,
      },
      SetOptions(merge: true),
    );

    batch.set(
      _deviceRef(userId, deviceId),
      <String, dynamic>{
        'userId': userId,
        'deviceId': deviceId,
        'registrationId': registrationId,
        'identityKeyPublic': base64Encode(
          identityKeyPair.getPublicKey().serialize(),
        ),
        'signedPreKey': <String, dynamic>{
          'id': signedPreKey.id,
          'publicKey': base64Encode(
            signedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signature': base64Encode(signedPreKey.signature),
          'createdAt': FieldValue.serverTimestamp(),
          'expiresAt': null,
        },
        'preKeyCount': preKeys.length,
        'capabilities': <String, dynamic>{'textMessaging': true},
        'status': 'active',
        'deviceOrdinal': int.tryParse(deviceId) ?? 1,
        'deviceNameCiphertext': null,
        'createdAt': FieldValue.serverTimestamp(),
        'lastSeenAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    for (final preKey in preKeys) {
      batch.set(
        _preKeysRef(userId, deviceId).doc('${preKey.id}'),
        <String, dynamic>{
          'userId': userId,
          'deviceId': deviceId,
          'preKeyId': '${preKey.id}',
          'publicKey': base64Encode(preKey.getKeyPair().publicKey.serialize()),
          'state': 'available',
          'uploadedAt': FieldValue.serverTimestamp(),
          'claimedAt': null,
          'claimedByUserIdHash': null,
        },
        SetOptions(merge: true),
      );
    }

    await batch.commit();
  }

  Future<void> updateDeviceRoutingToken({
    required String userId,
    required String deviceId,
    required String fcmToken,
    required String platform,
  }) {
    return _deviceRoutingRef(userId, deviceId).set(
      <String, dynamic>{
        'userId': userId,
        'deviceId': deviceId,
        'fcmToken': fcmToken,
        'platform': platform,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<List<SignalDeviceBundle>> fetchActiveDeviceBundles({
    required String userId,
  }) async {
    final snap = await _publicBundles
        .doc(userId)
        .collection('devices')
        .where('status', isEqualTo: 'active')
        .get();

    final userSnap = await _publicBundles.doc(userId).get();
    final userLabel = userSnap.data()?['label'] as String?;

    final bundles = snap.docs
        .map(
          (doc) => SignalDeviceBundle.fromFirestore(
            userId,
            doc.data(),
            userLabel: userLabel,
          ),
        )
        .toList(growable: false);

    bundles.sort((a, b) => a.numericDeviceId.compareTo(b.numericDeviceId));
    return bundles;
  }

  Future<SignalDeviceBundle> fetchDeviceBundle({
    required String userId,
    required String deviceId,
  }) async {
    final userSnap = await _publicBundles.doc(userId).get();
    final userLabel = userSnap.data()?['label'] as String?;

    final snap = await _deviceRef(userId, deviceId).get();
    final data = snap.data();
    if (data == null) {
      throw StateError('The requested device bundle does not exist.');
    }

    return SignalDeviceBundle.fromFirestore(
      userId,
      data,
      userLabel: userLabel,
    );
  }

  Future<PreKeyBundle> fetchAndConsumePreKeyBundle({
    required String recipientUserId,
    required String recipientDeviceId,
  }) async {
    final deviceSnap = await _deviceRef(recipientUserId, recipientDeviceId).get();
    if (!deviceSnap.exists) {
      throw StateError('Recipient device does not exist.');
    }

    final bundle = SignalDeviceBundle.fromFirestore(
      recipientUserId,
      deviceSnap.data()!,
    );

    final preKeyQuerySnap = await _preKeysRef(recipientUserId, recipientDeviceId)
        .where('state', isEqualTo: 'available')
        .limit(1)
        .get();

    if (preKeyQuerySnap.docs.isNotEmpty) {
      final candidateData = preKeyQuerySnap.docs.first.data();

      return PreKeyBundle(
        bundle.registrationId,
        bundle.numericDeviceId,
        int.parse(candidateData['preKeyId'] as String),
        Curve.decodePoint(
          base64Decode(candidateData['publicKey'] as String),
          0,
        ),
        bundle.signedPreKeyId,
        Curve.decodePoint(
          base64Decode(bundle.signedPreKeyPublicBase64),
          0,
        ),
        base64Decode(bundle.signedPreKeySignatureBase64),
        IdentityKey.fromBytes(base64Decode(bundle.identityKeyPublicBase64), 0),
      );
    }

    throw StateError('Recipient has no available one-time prekeys.');
  }

  Future<SignalEncryptedEnvelope> encryptMessageForDevice({
    required String senderUserId,
    required String recipientUserId,
    required String recipientDeviceId,
    required String plaintext,
  }) async {
    final remoteAddress = _remoteAddress(
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
    );

    final hasSession = await _signalStore.containsSession(remoteAddress);
    if (!hasSession) {
      final preKeyBundle = await fetchAndConsumePreKeyBundle(
        recipientUserId: recipientUserId,
        recipientDeviceId: recipientDeviceId,
      );

      final sessionBuilder = SessionBuilder.fromSignalStore(
        _signalStore,
        remoteAddress,
      );
      await sessionBuilder.processPreKeyBundle(preKeyBundle);
    }

    final sessionCipher = SessionCipher.fromStore(_signalStore, remoteAddress);
    final encrypted = await sessionCipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    return SignalEncryptedEnvelope(
      signalMessageType: encrypted.getType(),
      ciphertextBase64: base64Encode(encrypted.serialize()),
    );
  }

  Future<String> decryptEnvelope({
    required String senderUserId,
    required String senderDeviceId,
    required SignalEncryptedEnvelope envelope,
  }) async {
    final sessionCipher = SessionCipher.fromStore(
      _signalStore,
      _remoteAddress(
        recipientUserId: senderUserId,
        recipientDeviceId: senderDeviceId,
      ),
    );

    final raw = base64Decode(envelope.ciphertextBase64);
    Uint8List plaintextBytes;

    if (envelope.signalMessageType == CiphertextMessage.prekeyType) {
      plaintextBytes = await sessionCipher.decrypt(PreKeySignalMessage(raw));
    } else if (envelope.signalMessageType == CiphertextMessage.whisperType) {
      plaintextBytes = await sessionCipher.decryptFromSignal(
        SignalMessage.fromSerialized(raw),
      );
    } else {
      throw UnsupportedError(
        'Unsupported Signal message type: ${envelope.signalMessageType}',
      );
    }

    return utf8.decode(plaintextBytes);
  }

  Future<String> identityKeyDigest(String identityKeyPublicBase64) async {
    final digest = await Sha256().hash(base64Decode(identityKeyPublicBase64));
    return base64Encode(digest.bytes);
  }

  SignalProtocolAddress _remoteAddress({
    required String recipientUserId,
    required String recipientDeviceId,
  }) {
    return SignalProtocolAddress(
      recipientUserId,
      int.parse(recipientDeviceId),
    );
  }
}
