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

class ForumReply {
  const ForumReply({
    required this.id,
    required this.authorUserId,
    required this.authorLabel,
    required this.body,
    required this.createdAt,
    this.parentReplyId,
  });

  final String id;
  final String authorUserId;
  final String authorLabel;
  final String body;
  final DateTime createdAt;
  final String? parentReplyId;

  factory ForumReply.fromJson(Map<String, dynamic> json) {
    final ts = json['createdAt'];
    return ForumReply(
      id: json['id'] as String? ?? json['replyId'] as String? ?? '',
      authorUserId: json['authorUserId'] as String? ?? 'unknown',
      authorLabel: json['authorLabel'] as String? ?? 'Unknown',
      body: json['body'] as String? ?? '',
      createdAt: ts is Timestamp ? ts.toDate() : (ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now()),
      parentReplyId: json['parentReplyId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'replyId': id,
      'authorUserId': authorUserId,
      'authorLabel': authorLabel,
      'body': body,
      'createdAt': Timestamp.fromDate(createdAt),
      'parentReplyId': parentReplyId,
    };
  }
}

class ForumPost {
  const ForumPost({
    required this.id,
    required this.authorUserId,
    required this.authorLabel,
    required this.body,
    required this.createdAt,
    this.replyCount = 0,
    this.replies = const <ForumReply>[],
  });

  final String id;
  final String authorUserId;
  final String authorLabel;
  final String body;
  final DateTime createdAt;
  final int replyCount;
  final List<ForumReply> replies;

  factory ForumPost.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final ts = data['createdAt'];

    final repliesData = data['replies'] as List<dynamic>? ?? <dynamic>[];
    final repliesList = repliesData
        .whereType<Map<String, dynamic>>()
        .map((e) => ForumReply.fromJson(e))
        .toList(growable: false);

    return ForumPost(
      id: doc.id,
      authorUserId: data['authorUserId'] as String? ?? 'unknown',
      authorLabel: data['authorLabel'] as String? ?? 'Unknown',
      body: data['body'] as String? ?? '',
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      replyCount: data['replyCount'] as int? ?? repliesList.length,
      replies: repliesList,
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

  Future<void> addReply({
    required String postId,
    required String authorUserId,
    required String authorLabel,
    required String body,
    String? parentReplyId,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw StateError('Reply cannot be empty.');
    }

    final postRef = _firestore.collection('forums_posts').doc(postId);
    final replyRef = postRef.collection('replies').doc();
    
    final reply = ForumReply(
      id: replyRef.id,
      authorUserId: authorUserId,
      authorLabel: authorLabel,
      body: trimmed,
      createdAt: DateTime.now(),
      parentReplyId: parentReplyId,
    );

    final batch = _firestore.batch();
    batch.set(replyRef, reply.toJson());
    batch.update(postRef, <String, dynamic>{
      'replyCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    
    await batch.commit();
  }

  Stream<List<ForumReply>> streamReplies(String postId) {
    return _firestore
        .collection('forums_posts')
        .doc(postId)
        .collection('replies')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => ForumReply.fromJson(doc.data()))
            .toList(growable: false));
  }
}

class AppGroup {
  const AppGroup({
    required this.id,
    required this.groupId,
    required this.name,
    required this.createdBy,
    required this.ownerUserId,
    required this.createdAt,
    required this.memberCount,
    required this.memberUserIds,
  });

  final String id;
  final String groupId;
  final String name;
  final String createdBy;
  final String ownerUserId;
  final DateTime createdAt;
  final int memberCount;
  final List<String> memberUserIds;

  bool isMember(String userId) => memberUserIds.contains(userId);

  bool isOwner(String userId) => ownerUserId == userId;

  bool canAddMembers(String userId) => isMember(userId);

  bool canRemoveMembers(String userId) => isOwner(userId);

  factory AppGroup.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final ts = data['createdAt'];
    final rawMemberIds = data['memberUserIds'] as List<dynamic>?;
    final memberIds = (rawMemberIds ?? const <dynamic>[])
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final ownerUserId = data['ownerUserId'] as String? ??
        data['createdBy'] as String? ??
        'unknown';

    return AppGroup(
      id: doc.id,
      groupId: data['groupId'] as String? ?? doc.id,
      name: data['name'] as String? ?? 'Unnamed Group',
      createdBy: data['createdBy'] as String? ?? 'unknown',
      ownerUserId: ownerUserId,
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      memberCount: data['memberCount'] as int? ?? memberIds.length,
      memberUserIds: memberIds,
    );
  }
}

class AppGroupMember {
  const AppGroupMember({required this.userId, required this.isOwner});

  final String userId;
  final bool isOwner;

  String get roleLabel => isOwner ? 'Owner' : 'Participant';
}

class AppUserProfile {
  const AppUserProfile({required this.userId, required this.label});

  final String userId;
  final String label;

  factory AppUserProfile.fromPublicBundleDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    final userId = (data['userId'] as String?)?.trim();
    final resolvedUserId =
        (userId == null || userId.isEmpty) ? doc.id : userId;

    String? preferredLabel;
    for (final candidate in <String?>[
      data['label'] as String?,
      data['displayName'] as String?,
      data['name'] as String?,
    ]) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        preferredLabel = trimmed;
        break;
      }
    }

    return AppUserProfile(
      userId: resolvedUserId,
      label: (preferredLabel == null || preferredLabel.isEmpty)
          ? resolvedUserId
          : preferredLabel,
    );
  }
}

class AppGroupsService {
  AppGroupsService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<AppGroup>> streamGroups({
    String? currentUserId,
    int limit = 30,
  }) {
    Query<Map<String, dynamic>> query = _firestore
        .collection('app_groups')
        .limit(limit);

    final trimmedUserId = currentUserId?.trim();
    if (trimmedUserId != null && trimmedUserId.isNotEmpty) {
      query = query.where('memberUserIds', arrayContains: trimmedUserId);
    }

    return query.snapshots().map((snap) {
      final groups = snap.docs
          .map((doc) => AppGroup.fromDoc(doc))
          .toList(growable: false);
      groups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return groups;
    });
  }

  Stream<List<AppGroupMember>> streamGroupMembers({required String groupId}) {
    return _firestore.collection('app_groups').doc(groupId).snapshots().map((doc) {
      final data = doc.data() ?? const <String, dynamic>{};
      final ownerUserId = data['ownerUserId'] as String? ??
          data['createdBy'] as String? ??
          '';
      final rawMemberIds = data['memberUserIds'] as List<dynamic>?;
      final memberIds = (rawMemberIds ?? const <dynamic>[])
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();

      return memberIds
          .map(
            (memberId) => AppGroupMember(
              userId: memberId,
              isOwner: memberId == ownerUserId,
            ),
          )
          .toList(growable: false);
    });
  }

  Stream<List<AppUserProfile>> streamAvailableUsers({int limit = 200}) {
    return _firestore
        .collection('public_user_bundles')
        .limit(limit)
        .snapshots()
        .map((snap) {
      final users = snap.docs
          .map((doc) => AppUserProfile.fromPublicBundleDoc(doc))
          .toList(growable: false);
      users.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      return users;
    });
  }

  Future<void> createGroup({
    required String createdBy,
    required String name,
    List<String> initialMemberUserIds = const <String>[],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw StateError('Group name cannot be empty.');
    }

    final initialMembers = <String>{
      createdBy,
      ...initialMemberUserIds
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    }.toList(growable: false)
      ..sort();

    final groupRef = _firestore.collection('app_groups').doc();
    await groupRef.set(<String, dynamic>{
      'groupId': groupRef.id,
      'name': trimmed,
      'createdBy': createdBy,
      'ownerUserId': createdBy,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'memberUserIds': initialMembers,
      'memberCount': initialMembers.length,
    });
  }

  Future<void> addMember({
    required String groupId,
    required String addedBy,
    required String memberUserId,
  }) async {
    final trimmedMemberId = memberUserId.trim();
    if (trimmedMemberId.isEmpty) {
      throw StateError('Member user id cannot be empty.');
    }

    final groupRef = _firestore.collection('app_groups').doc(groupId);
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(groupRef);
      if (!snap.exists) {
        throw StateError('Group not found.');
      }

      final group = AppGroup.fromDoc(snap);
      if (!group.canAddMembers(addedBy)) {
        throw StateError('Only group members can add participants.');
      }
      if (group.memberUserIds.contains(trimmedMemberId)) {
        return;
      }

      final updatedMembers = <String>{
        ...group.memberUserIds,
        trimmedMemberId,
      }.toList(growable: false)
        ..sort();

      tx.update(groupRef, <String, dynamic>{
        'memberUserIds': updatedMembers,
        'memberCount': updatedMembers.length,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> removeMember({
    required String groupId,
    required String removedBy,
    required String memberUserId,
  }) async {
    final trimmedMemberId = memberUserId.trim();
    if (trimmedMemberId.isEmpty) {
      throw StateError('Member user id cannot be empty.');
    }

    final groupRef = _firestore.collection('app_groups').doc(groupId);
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(groupRef);
      if (!snap.exists) {
        throw StateError('Group not found.');
      }

      final group = AppGroup.fromDoc(snap);
      if (!group.isOwner(removedBy)) {
        throw StateError('Only the group owner can remove participants.');
      }
      if (trimmedMemberId == group.ownerUserId) {
        throw StateError('The owner cannot be removed from the group.');
      }
      if (!group.memberUserIds.contains(trimmedMemberId)) {
        return;
      }

      final updatedMembers = group.memberUserIds
          .where((id) => id != trimmedMemberId)
          .toList(growable: false)
        ..sort();

      tx.update(groupRef, <String, dynamic>{
        'memberUserIds': updatedMembers,
        'memberCount': updatedMembers.length,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}
