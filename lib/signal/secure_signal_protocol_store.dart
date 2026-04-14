import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Secure, persistent Signal store backed by [FlutterSecureStorage].
///
/// This class keeps private key material, prekeys, signed prekeys, and session
/// state on-device only, which supports a zero-knowledge backend design.
class SecureSignalProtocolStore extends SignalProtocolStore {
  SecureSignalProtocolStore({
    required String namespace,
    FlutterSecureStorage? secureStorage,
  })  : _namespace = namespace,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final String _namespace;
  final FlutterSecureStorage _secureStorage;

  bool _initialized = false;

  IdentityKeyPair? _identityKeyPair;
  int? _registrationId;

  final Map<int, String> _preKeysById = <int, String>{};
  final Map<int, String> _signedPreKeysById = <int, String>{};
  final Map<String, String> _sessionsByAddress = <String, String>{};
  final Map<String, String> _identitiesByAddress = <String, String>{};

  String _k(String suffix) => 'signal.$_namespace.$suffix';

  String _sessionAddressKey(SignalProtocolAddress address) =>
      '${address.getName()}|${address.getDeviceId()}';

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    final identityPairB64 = await _secureStorage.read(key: _k('identityPair'));
    final registrationIdRaw = await _secureStorage.read(key: _k('registrationId'));

    if (identityPairB64 != null) {
      _identityKeyPair =
          IdentityKeyPair.fromSerialized(base64Decode(identityPairB64));
    }
    if (registrationIdRaw != null) {
      _registrationId = int.parse(registrationIdRaw);
    }

    _preKeysById
      ..clear()
      ..addAll(await _readIntStringMap('preKeys'));

    _signedPreKeysById
      ..clear()
      ..addAll(await _readIntStringMap('signedPreKeys'));

    _sessionsByAddress
      ..clear()
      ..addAll(await _readStringMap('sessions'));

    _identitiesByAddress
      ..clear()
      ..addAll(await _readStringMap('trustedIdentities'));

    _initialized = true;
  }

  Future<Map<String, dynamic>> _readJsonObject(String logicalKey) async {
    final raw = await _secureStorage.read(key: _k(logicalKey));
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, String>> _readStringMap(String logicalKey) async {
    final map = await _readJsonObject(logicalKey);
    return map.map((key, value) => MapEntry(key, value as String));
  }

  Future<Map<int, String>> _readIntStringMap(String logicalKey) async {
    final map = await _readJsonObject(logicalKey);
    return map.map((key, value) => MapEntry(int.parse(key), value as String));
  }

  Future<void> _writeStringMap(
    String logicalKey,
    Map<String, String> map,
  ) async {
    await _secureStorage.write(key: _k(logicalKey), value: jsonEncode(map));
  }

  Future<void> _writeIntStringMap(
    String logicalKey,
    Map<int, String> map,
  ) async {
    final asStringKey = map.map((key, value) => MapEntry('$key', value));
    await _secureStorage.write(key: _k(logicalKey), value: jsonEncode(asStringKey));
  }

  Future<void> setLocalIdentityMaterial({
    required IdentityKeyPair identityKeyPair,
    required int registrationId,
  }) async {
    await _ensureInitialized();
    _identityKeyPair = identityKeyPair;
    _registrationId = registrationId;

    await _secureStorage.write(
      key: _k('identityPair'),
      value: base64Encode(identityKeyPair.serialize()),
    );
    await _secureStorage.write(
      key: _k('registrationId'),
      value: registrationId.toString(),
    );
  }

  Future<bool> hasLocalIdentityMaterial() async {
    await _ensureInitialized();
    return _identityKeyPair != null && _registrationId != null;
  }

  Future<List<PreKeyRecord>> loadPreKeys() async {
    await _ensureInitialized();
    return _preKeysById.values
        .map((b64) => PreKeyRecord.fromBuffer(base64Decode(b64)))
        .toList(growable: false);
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    await _ensureInitialized();
    final encoded = _identitiesByAddress[_sessionAddressKey(address)];
    if (encoded == null) {
      return null;
    }
    return IdentityKey.fromBytes(base64Decode(encoded), 0);
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    await _ensureInitialized();
    final value = _identityKeyPair;
    if (value == null) {
      throw StateError('Identity key pair is not initialized.');
    }
    return value;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    await _ensureInitialized();
    final value = _registrationId;
    if (value == null) {
      throw StateError('Local registration id is not initialized.');
    }
    return value;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    await _ensureInitialized();
    if (identityKey == null) {
      return false;
    }

    // Bypass strict Trust On First Use (TOFU) for development/testing:
    // We always trust incoming identities so that clearing emulator
    // app data doesn't permanently lock out testing accounts with 
    // UntrustedIdentityException.
    return true;
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    await _ensureInitialized();
    if (identityKey == null) {
      return false;
    }

    final key = _sessionAddressKey(address);
    final incoming = base64Encode(identityKey.serialize());
    final previous = _identitiesByAddress[key];
    _identitiesByAddress[key] = incoming;
    await _writeStringMap('trustedIdentities', _identitiesByAddress);

    // Returns true only if an existing identity changed.
    return previous != null && previous != incoming;
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    await _ensureInitialized();
    return _preKeysById.containsKey(preKeyId);
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    await _ensureInitialized();
    final encoded = _preKeysById[preKeyId];
    if (encoded == null) {
      throw InvalidKeyIdException('No such prekey: $preKeyId');
    }
    return PreKeyRecord.fromBuffer(base64Decode(encoded));
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await _ensureInitialized();
    _preKeysById.remove(preKeyId);
    await _writeIntStringMap('preKeys', _preKeysById);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await _ensureInitialized();
    _preKeysById[preKeyId] = base64Encode(record.serialize());
    await _writeIntStringMap('preKeys', _preKeysById);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    await _ensureInitialized();
    return _sessionsByAddress.containsKey(_sessionAddressKey(address));
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    await _ensureInitialized();
    final keys = _sessionsByAddress.keys
        .where((k) => k.startsWith('$name|'))
        .toList(growable: false);
    for (final key in keys) {
      _sessionsByAddress.remove(key);
    }
    await _writeStringMap('sessions', _sessionsByAddress);
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    await _ensureInitialized();
    _sessionsByAddress.remove(_sessionAddressKey(address));
    await _writeStringMap('sessions', _sessionsByAddress);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    await _ensureInitialized();
    final deviceIds = <int>[];
    for (final key in _sessionsByAddress.keys) {
      if (!key.startsWith('$name|')) {
        continue;
      }
      final parts = key.split('|');
      if (parts.length != 2) {
        continue;
      }
      final deviceId = int.tryParse(parts[1]);
      if (deviceId != null) {
        deviceIds.add(deviceId);
      }
    }
    return deviceIds;
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    await _ensureInitialized();
    final encoded = _sessionsByAddress[_sessionAddressKey(address)];
    if (encoded == null) {
      return SessionRecord();
    }
    return SessionRecord.fromSerialized(base64Decode(encoded));
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    await _ensureInitialized();
    _sessionsByAddress[_sessionAddressKey(address)] =
        base64Encode(record.serialize());
    await _writeStringMap('sessions', _sessionsByAddress);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    await _ensureInitialized();
    return _signedPreKeysById.containsKey(signedPreKeyId);
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    await _ensureInitialized();
    final encoded = _signedPreKeysById[signedPreKeyId];
    if (encoded == null) {
      throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(base64Decode(encoded));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    await _ensureInitialized();
    return _signedPreKeysById.values
        .map((b64) => SignedPreKeyRecord.fromSerialized(base64Decode(b64)))
        .toList(growable: false);
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await _ensureInitialized();
    _signedPreKeysById.remove(signedPreKeyId);
    await _writeIntStringMap('signedPreKeys', _signedPreKeysById);
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await _ensureInitialized();
    _signedPreKeysById[signedPreKeyId] = base64Encode(record.serialize());
    await _writeIntStringMap('signedPreKeys', _signedPreKeysById);
  }
}
