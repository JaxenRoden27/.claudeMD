import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalOptions {
  const LocalOptions({
    required this.autoSyncEnabled,
    required this.multiDeviceHints,
    required this.preferredCamera,
  });

  final bool autoSyncEnabled;
  final bool multiDeviceHints;
  final String preferredCamera;

  LocalOptions copyWith({
    bool? autoSyncEnabled,
    bool? multiDeviceHints,
    String? preferredCamera,
  }) {
    return LocalOptions(
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      multiDeviceHints: multiDeviceHints ?? this.multiDeviceHints,
      preferredCamera: preferredCamera ?? this.preferredCamera,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'autoSyncEnabled': autoSyncEnabled,
      'multiDeviceHints': multiDeviceHints,
      'preferredCamera': preferredCamera,
    };
  }

  factory LocalOptions.fromJson(Map<String, dynamic> json) {
    return LocalOptions(
      autoSyncEnabled: json['autoSyncEnabled'] as bool? ?? true,
      multiDeviceHints: json['multiDeviceHints'] as bool? ?? true,
      preferredCamera: json['preferredCamera'] as String? ?? 'rear',
    );
  }

  static const LocalOptions defaults = LocalOptions(
    autoSyncEnabled: true,
    multiDeviceHints: true,
    preferredCamera: 'rear',
  );
}

class LocalOptionsService {
  LocalOptionsService();

  static const String _storageKey = 'app.local_options.v1';

  Future<LocalOptions> load() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = prefs.getString(_storageKey);
    if (payload == null || payload.isEmpty) {
      return LocalOptions.defaults;
    }

    try {
      final parsed = jsonDecode(payload) as Map<String, dynamic>;
      return LocalOptions.fromJson(parsed);
    } catch (_) {
      return LocalOptions.defaults;
    }
  }

  Future<void> save(LocalOptions options) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(options.toJson()));
  }
}

class AccountQrPayload {
  const AccountQrPayload({
    required this.userId,
    required this.deviceId,
    required this.label,
  });

  final String userId;
  final String deviceId;
  final String label;

  factory AccountQrPayload.fromJson(Map<String, dynamic> json) {
    return AccountQrPayload(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      label: json['label'] as String? ?? 'Imported account',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'userId': userId,
      'deviceId': deviceId,
      'label': label,
    };
  }

  static AccountQrPayload? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (decoded['userId'] is! String || decoded['deviceId'] is! String) {
        return null;
      }
      return AccountQrPayload.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}

class ForumPost {
  const ForumPost({
    required this.id,
    required this.authorUserId,
    required this.authorLabel,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String authorUserId;
  final String authorLabel;
  final String body;
  final DateTime createdAt;

  factory ForumPost.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final ts = data['createdAt'];
    return ForumPost(
      id: doc.id,
      authorUserId: data['authorUserId'] as String? ?? 'unknown',
      authorLabel: data['authorLabel'] as String? ?? 'Unknown',
      body: data['body'] as String? ?? '',
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }
}

class ForumsService {
  ForumsService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<ForumPost>> streamLatestPosts({int limit = 30}) {
    return _firestore
        .collection('forums_posts')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => ForumPost.fromDoc(doc))
              .toList(growable: false),
        );
  }

  Future<void> createPost({
    required String authorUserId,
    required String authorLabel,
    required String body,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw StateError('Forum post cannot be empty.');
    }

    await _firestore.collection('forums_posts').add(<String, dynamic>{
      'authorUserId': authorUserId,
      'authorLabel': authorLabel,
      'body': trimmed,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

class AppGroup {
  const AppGroup({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.memberCount,
  });

  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;
  final int memberCount;

  factory AppGroup.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final ts = data['createdAt'];
    return AppGroup(
      id: doc.id,
      name: data['name'] as String? ?? 'Unnamed Group',
      createdBy: data['createdBy'] as String? ?? 'unknown',
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      memberCount: data['memberCount'] as int? ?? 0,
    );
  }
}

class AppGroupsService {
  AppGroupsService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<AppGroup>> streamGroups({int limit = 30}) {
    return _firestore
        .collection('app_groups')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => AppGroup.fromDoc(doc))
              .toList(growable: false),
        );
  }

  Future<void> createGroup({
    required String createdBy,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw StateError('Group name cannot be empty.');
    }

    await _firestore.collection('app_groups').add(<String, dynamic>{
      'name': trimmed,
      'createdBy': createdBy,
      'createdAt': FieldValue.serverTimestamp(),
      'memberCount': 1,
    });
  }
}
