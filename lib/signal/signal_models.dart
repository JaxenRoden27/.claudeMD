import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

const secureImageMessagePrefix = '[image-secure-v1] ';

class SignalEncryptedEnvelope {
  SignalEncryptedEnvelope({
    required this.signalMessageType,
    required this.ciphertextBase64,
  });

  final int signalMessageType;
  final String ciphertextBase64;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'signalMessageType': signalMessageType,
      'ciphertext': ciphertextBase64,
    };
  }

  String toPayload() => jsonEncode(toJson());

  factory SignalEncryptedEnvelope.fromPayload(String payload) {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    return SignalEncryptedEnvelope(
      signalMessageType: decoded['signalMessageType'] as int,
      ciphertextBase64: decoded['ciphertext'] as String,
    );
  }
}

class SignalDeviceBundle {
  SignalDeviceBundle({
    required this.userId,
    required this.deviceId,
    required this.registrationId,
    required this.identityKeyPublicBase64,
    required this.signedPreKeyId,
    required this.signedPreKeyPublicBase64,
    required this.signedPreKeySignatureBase64,
    required this.preKeyCount,
    required this.status,
  });

  final String userId;
  final String deviceId;
  final int registrationId;
  final String identityKeyPublicBase64;
  final int signedPreKeyId;
  final String signedPreKeyPublicBase64;
  final String signedPreKeySignatureBase64;
  final int preKeyCount;
  final String status;

  int get numericDeviceId => int.parse(deviceId);

  factory SignalDeviceBundle.fromFirestore(
    String userId,
    Map<String, dynamic> data,
  ) {
    final signedPreKey = data['signedPreKey'] as Map<String, dynamic>;
    return SignalDeviceBundle(
      userId: userId,
      deviceId: data['deviceId'] as String,
      registrationId: data['registrationId'] as int,
      identityKeyPublicBase64: data['identityKeyPublic'] as String,
      signedPreKeyId: signedPreKey['id'] as int,
      signedPreKeyPublicBase64: signedPreKey['publicKey'] as String,
      signedPreKeySignatureBase64: signedPreKey['signature'] as String,
      preKeyCount: data['preKeyCount'] as int? ?? 0,
      status: data['status'] as String? ?? 'active',
    );
  }
}

class SignalDeliveryRecord {
  SignalDeliveryRecord({
    required this.deliveryId,
    required this.conversationId,
    required this.messageId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.recipientUserId,
    required this.recipientDeviceId,
    required this.messageType,
    required this.protocolVersion,
    required this.envelope,
    required this.createdAt,
    required this.deliveryState,
    this.attachmentRefs = const <String>[],
  });

  final String deliveryId;
  final String conversationId;
  final String messageId;
  final String senderUserId;
  final String senderDeviceId;
  final String recipientUserId;
  final String recipientDeviceId;
  final String messageType;
  final int protocolVersion;
  final SignalEncryptedEnvelope envelope;
  final DateTime createdAt;
  final String deliveryState;
  final List<String> attachmentRefs;

  Map<String, dynamic> toFirestore() {
    return <String, dynamic>{
      'conversationId': conversationId,
      'messageId': messageId,
      'senderUserId': senderUserId,
      'senderDeviceId': senderDeviceId,
      'recipientUserId': recipientUserId,
      'recipientDeviceId': recipientDeviceId,
      'messageType': messageType,
      'protocolVersion': protocolVersion,
      'envelopeCiphertext': envelope.toPayload(),
      'attachmentRefs': attachmentRefs,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': null,
      'serverOrder': null,
      'deliveryState': deliveryState,
    };
  }

  Map<String, String> toWakePayload() {
    return <String, String>{
      'type': 'new_message',
      'conversationId': conversationId,
      'deliveryId': deliveryId,
      'recipientUserId': recipientUserId,
      'recipientDeviceId': recipientDeviceId,
    };
  }

  factory SignalDeliveryRecord.fromFirestore(
    String deliveryId,
    Map<String, dynamic> data,
  ) {
    final timestamp = data['createdAt'];
    return SignalDeliveryRecord(
      deliveryId: deliveryId,
      conversationId: data['conversationId'] as String,
      messageId: data['messageId'] as String,
      senderUserId: data['senderUserId'] as String,
      senderDeviceId: data['senderDeviceId'] as String,
      recipientUserId: data['recipientUserId'] as String,
      recipientDeviceId: data['recipientDeviceId'] as String,
      messageType: data['messageType'] as String,
      protocolVersion: data['protocolVersion'] as int,
      envelope: SignalEncryptedEnvelope.fromPayload(
        data['envelopeCiphertext'] as String,
      ),
      attachmentRefs:
          ((data['attachmentRefs'] as List<dynamic>?) ?? const <dynamic>[])
              .whereType<String>()
              .toList(growable: false),
      createdAt: timestamp is Timestamp ? timestamp.toDate() : DateTime.now(),
      deliveryState: data['deliveryState'] as String? ?? 'queued',
    );
  }
}

class SecureImageAttachmentPayload {
  const SecureImageAttachmentPayload({
    required this.attachmentId,
    required this.conversationId,
    required this.storagePath,
    required this.mimeType,
    required this.fileKeyBase64,
    required this.fileNonceBase64,
    required this.fileMacBase64,
    required this.ciphertextHash,
    required this.sizePadded,
  });

  final String attachmentId;
  final String conversationId;
  final String storagePath;
  final String mimeType;
  final String fileKeyBase64;
  final String fileNonceBase64;
  final String fileMacBase64;
  final String ciphertextHash;
  final int sizePadded;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'v': 1,
      'kind': 'image',
      'attachmentId': attachmentId,
      'conversationId': conversationId,
      'storagePath': storagePath,
      'mimeType': mimeType,
      'fileKey': fileKeyBase64,
      'fileNonce': fileNonceBase64,
      'fileMac': fileMacBase64,
      'ciphertextHash': ciphertextHash,
      'sizePadded': sizePadded,
    };
  }

  String toPlaintextPayload() =>
      '$secureImageMessagePrefix${jsonEncode(toJson())}';

  factory SecureImageAttachmentPayload.fromJson(Map<String, dynamic> json) {
    return SecureImageAttachmentPayload(
      attachmentId: json['attachmentId'] as String,
      conversationId: json['conversationId'] as String,
      storagePath: json['storagePath'] as String,
      mimeType: json['mimeType'] as String,
      fileKeyBase64: json['fileKey'] as String,
      fileNonceBase64: json['fileNonce'] as String,
      fileMacBase64: json['fileMac'] as String,
      ciphertextHash: json['ciphertextHash'] as String,
      sizePadded: json['sizePadded'] as int,
    );
  }

  static SecureImageAttachmentPayload? tryParseFromPlaintext(String plaintext) {
    final trimmed = plaintext.trim();
    if (!trimmed.startsWith(secureImageMessagePrefix)) {
      return null;
    }

    final payload = trimmed.substring(secureImageMessagePrefix.length).trim();
    if (payload.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      if (decoded['v'] != 1 || decoded['kind'] != 'image') {
        return null;
      }

      return SecureImageAttachmentPayload.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}

class LocalChatMessage {
  const LocalChatMessage({
    required this.localId,
    required this.conversationId,
    required this.deliveryId,
    required this.messageId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.recipientUserId,
    required this.recipientDeviceId,
    required this.plaintext,
    required this.createdAt,
    required this.outgoing,
    required this.deliveryState,
  });

  final int? localId;
  final String deliveryId;
  final String conversationId;
  final String messageId;
  final String senderUserId;
  final String senderDeviceId;
  final String recipientUserId;
  final String recipientDeviceId;
  final String plaintext;
  final DateTime createdAt;
  final bool outgoing;
  final String deliveryState;
}

class LocalTrustRecord {
  const LocalTrustRecord({
    required this.userId,
    required this.deviceId,
    required this.identityKeyHash,
    required this.verified,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.label,
  });

  final String userId;
  final String deviceId;
  final String identityKeyHash;
  final bool verified;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final String? label;
}
