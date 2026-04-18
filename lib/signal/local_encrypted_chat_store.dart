import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'signal_models.dart';

class LocalEncryptedChatStore {
  LocalEncryptedChatStore({
    required String namespace,
    FlutterSecureStorage? secureStorage,
  })  : _namespace = namespace,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _dbVersion = 2;
  static final _aes = AesGcm.with256bits();

  final String _namespace;
  final FlutterSecureStorage _secureStorage;

  Database? _database;
  SecretKey? _secretKey;

  String get _masterKeyStorageKey => 'local_chat_store.$_namespace.master_key';

  Future<Database> _openDatabase() async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }

    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, 'signal_local_$_namespace.db');
    final db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            delivery_id TEXT NOT NULL UNIQUE,
            conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            sender_user_id TEXT NOT NULL,
            sender_device_id TEXT NOT NULL,
            recipient_user_id TEXT NOT NULL,
            recipient_device_id TEXT NOT NULL,
            body_ciphertext TEXT NOT NULL,
            created_at_millis INTEGER NOT NULL,
            outgoing INTEGER NOT NULL,
            delivery_state TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE trust_state(
            address_key TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            identity_key_hash TEXT NOT NULL,
            verified INTEGER NOT NULL,
            first_seen_at_millis INTEGER NOT NULL,
            last_seen_at_millis INTEGER NOT NULL,
            label TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE trust_state ADD COLUMN label TEXT;');
        }
      },
    );

    _database = db;
    return db;
  }

  Future<SecretKey> _loadSecretKey() async {
    final existing = _secretKey;
    if (existing != null) {
      return existing;
    }

    final stored = await _secureStorage.read(key: _masterKeyStorageKey);
    late final Uint8List bytes;
    if (stored == null) {
      final random = Random.secure();
      bytes = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      await _secureStorage.write(
        key: _masterKeyStorageKey,
        value: base64Encode(bytes),
      );
    } else {
      bytes = base64Decode(stored);
    }

    final key = SecretKey(bytes);
    _secretKey = key;
    return key;
  }

  Future<String> _encryptText(String plaintext) async {
    final secretKey = await _loadSecretKey();
    final random = Random.secure();
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final secretBox = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );

    return jsonEncode(<String, String>{
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  Future<String> _decryptText(String payload) async {
    final secretKey = await _loadSecretKey();
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    final box = SecretBox(
      base64Decode(decoded['ciphertext'] as String),
      nonce: base64Decode(decoded['nonce'] as String),
      mac: Mac(base64Decode(decoded['mac'] as String)),
    );
    final cleartext = await _aes.decrypt(box, secretKey: secretKey);
    return utf8.decode(cleartext);
  }

  Future<void> upsertMessage(LocalChatMessage message) async {
    final db = await _openDatabase();
    final ciphertext = await _encryptText(message.plaintext);

    await db.insert(
      'messages',
      <String, Object?>{
        'delivery_id': message.deliveryId,
        'conversation_id': message.conversationId,
        'message_id': message.messageId,
        'sender_user_id': message.senderUserId,
        'sender_device_id': message.senderDeviceId,
        'recipient_user_id': message.recipientUserId,
        'recipient_device_id': message.recipientDeviceId,
        'body_ciphertext': ciphertext,
        'created_at_millis': message.createdAt.millisecondsSinceEpoch,
        'outgoing': message.outgoing ? 1 : 0,
        'delivery_state': message.deliveryState,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasDelivery(String deliveryId) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'messages',
      columns: const <String>['delivery_id'],
      where: 'delivery_id = ?',
      whereArgs: <Object?>[deliveryId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<LocalChatMessage>> loadConversationMessages(
    String conversationId,
  ) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at_millis ASC, id ASC',
    );

    final messages = <LocalChatMessage>[];
    for (final row in rows) {
      messages.add(
        LocalChatMessage(
          localId: row['id'] as int?,
          deliveryId: row['delivery_id'] as String,
          conversationId: row['conversation_id'] as String,
          messageId: row['message_id'] as String,
          senderUserId: row['sender_user_id'] as String,
          senderDeviceId: row['sender_device_id'] as String,
          recipientUserId: row['recipient_user_id'] as String,
          recipientDeviceId: row['recipient_device_id'] as String,
          plaintext: await _decryptText(row['body_ciphertext'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at_millis'] as int,
          ),
          outgoing: (row['outgoing'] as int) == 1,
          deliveryState: row['delivery_state'] as String,
        ),
      );
    }

    return messages;
  }

  Future<void> upsertTrustRecord({
    required String userId,
    required String deviceId,
    required String identityKeyHash,
    bool verified = false,
    String? label,
  }) async {
    final db = await _openDatabase();
    final addressKey = '$userId|$deviceId';
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.query(
      'trust_state',
      where: 'address_key = ?',
      whereArgs: <Object?>[addressKey],
      limit: 1,
    );

    final firstSeenAt = existing.isEmpty
        ? now
        : existing.first['first_seen_at_millis'] as int;

    final resolvedLabel = label ?? (existing.isNotEmpty ? existing.first['label'] as String? : null);

    await db.insert(
      'trust_state',
      <String, Object?>{
        'address_key': addressKey,
        'user_id': userId,
        'device_id': deviceId,
        'identity_key_hash': identityKeyHash,
        'verified': verified ? 1 : 0,
        'first_seen_at_millis': firstSeenAt,
        'last_seen_at_millis': now,
        'label': resolvedLabel,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<LocalTrustRecord>> loadTrustRecordsForUser(String userId) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'trust_state',
      where: 'user_id = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'device_id ASC',
    );

    return rows
        .map(
          (row) => LocalTrustRecord(
            userId: row['user_id'] as String,
            deviceId: row['device_id'] as String,
            identityKeyHash: row['identity_key_hash'] as String,
            verified: (row['verified'] as int) == 1,
            firstSeenAt: DateTime.fromMillisecondsSinceEpoch(
              row['first_seen_at_millis'] as int,
            ),
            lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
              row['last_seen_at_millis'] as int,
            ),
            label: row['label'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<List<LocalTrustRecord>> loadAllKnownPeers() async {
    final db = await _openDatabase();
    final rows = await db.query(
      'trust_state',
      orderBy: 'last_seen_at_millis DESC',
    );

    return rows
        .map(
          (row) => LocalTrustRecord(
            userId: row['user_id'] as String,
            deviceId: row['device_id'] as String,
            identityKeyHash: row['identity_key_hash'] as String,
            verified: (row['verified'] as int) == 1,
            firstSeenAt: DateTime.fromMillisecondsSinceEpoch(
              row['first_seen_at_millis'] as int,
            ),
            lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
              row['last_seen_at_millis'] as int,
            ),
            label: row['label'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<void> deleteTrustRecord(String userId, String deviceId) async {
    final db = await _openDatabase();
    final addressKey = '$userId|$deviceId';
    await db.delete(
      'trust_state',
      where: 'address_key = ?',
      whereArgs: <Object?>[addressKey],
    );
  }

  Future<void> deleteConversationMessages(String conversationId) async {
    final db = await _openDatabase();
    await db.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
    );
  }
}
