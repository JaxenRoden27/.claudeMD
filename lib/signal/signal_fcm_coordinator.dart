import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'signal_message_repository.dart';
import 'signal_models.dart';
import 'signal_service.dart';

class SignalFcmCoordinator {
  SignalFcmCoordinator({required this.firestore})
      : _messaging = FirebaseMessaging.instance;

  final FirebaseFirestore firestore;
  final FirebaseMessaging _messaging;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  Future<void> initializeForeground({
    required String localUserId,
    required String localDeviceId,
    required SignalMessageRepository repository,
    required Future<void> Function(LocalChatMessage message) onMessageSynced,
  }) async {
    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    await _registerRoutingToken(repository);

    _subscriptions.add(
      FirebaseMessaging.onMessage.listen((message) async {
        final synced = await _syncWakeSignal(
          firestore: firestore,
          localUserId: localUserId,
          localDeviceId: localDeviceId,
          data: message.data,
        );
        if (synced != null) {
          await onMessageSynced(synced);
        }
      }),
    );

    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen((message) async {
        final synced = await _syncWakeSignal(
          firestore: firestore,
          localUserId: localUserId,
          localDeviceId: localDeviceId,
          data: message.data,
        );
        if (synced != null) {
          await onMessageSynced(synced);
        }
      }),
    );

    _subscriptions.add(
      _messaging.onTokenRefresh.listen((token) async {
        await repository.updateRoutingToken(
          fcmToken: token,
          platform: _platformName,
        );
      }),
    );
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  String get _platformName {
    if (kIsWeb) {
      return 'web';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      _ => 'unknown',
    };
  }

  Future<void> _registerRoutingToken(SignalMessageRepository repository) async {
    final token = await _messaging.getToken();
    if (token == null || token.isEmpty) {
      return;
    }

    await repository.updateRoutingToken(
      fcmToken: token,
      platform: _platformName,
    );
  }
}

Future<LocalChatMessage?> _syncWakeSignal({
  required FirebaseFirestore firestore,
  required String localUserId,
  required String localDeviceId,
  required Map<String, dynamic> data,
}) async {
  if (data['type'] != 'new_message') {
    return null;
  }

  final conversationId = data['conversationId'] as String?;
  final deliveryId = data['deliveryId'] as String?;
  final recipientUserId = data['recipientUserId'] as String?;
  final recipientDeviceId = data['recipientDeviceId'] as String?;

  if (conversationId == null ||
      deliveryId == null ||
      recipientUserId != localUserId ||
      recipientDeviceId != localDeviceId) {
    return null;
  }

  final repository = SignalMessageRepository.forLocalDevice(
    firestore: firestore,
    localUserId: localUserId,
    localDeviceId: localDeviceId,
  );
  return repository.syncSingleDelivery(
    conversationId: conversationId,
    deliveryId: deliveryId,
  );
}

@pragma('vm:entry-point')
Future<void> signalFcmBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final localUserId = message.data['recipientUserId'] as String?;
  final localDeviceId =
      message.data['recipientDeviceId'] as String? ?? SignalService.defaultDeviceId;
  if (localUserId == null || localUserId.isEmpty) {
    return;
  }

  await _syncWakeSignal(
    firestore: FirebaseFirestore.instance,
    localUserId: localUserId,
    localDeviceId: localDeviceId,
    data: message.data,
  );
}
