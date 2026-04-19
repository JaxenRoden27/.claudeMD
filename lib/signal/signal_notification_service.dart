import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'signal_message_repository.dart';
import 'signal_models.dart';

class SignalNotificationRoute {
  const SignalNotificationRoute({
    required this.conversationId,
    required this.peerUserId,
    this.deliveryId,
  });

  final String conversationId;
  final String peerUserId;
  final String? deliveryId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'conversationId': conversationId,
      'peerUserId': peerUserId,
      if (deliveryId != null) 'deliveryId': deliveryId,
    };
  }

  String toPayload() => jsonEncode(toJson());

  static SignalNotificationRoute? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final conversationId = _normalizedString(decoded['conversationId']);
      final peerUserId = _normalizedString(decoded['peerUserId']);
      if (conversationId == null || peerUserId == null) {
        return null;
      }

      return SignalNotificationRoute(
        conversationId: conversationId,
        peerUserId: peerUserId,
        deliveryId: _normalizedString(decoded['deliveryId']),
      );
    } catch (_) {
      return null;
    }
  }

  static SignalNotificationRoute fromMessage({
    required LocalChatMessage message,
    required String localUserId,
  }) {
    final peerUserId = message.senderUserId == localUserId
        ? message.recipientUserId
        : message.senderUserId;

    return SignalNotificationRoute(
      conversationId: message.conversationId,
      peerUserId: peerUserId,
      deliveryId: message.deliveryId,
    );
  }

  static SignalNotificationRoute? fromRemoteData({
    required Map<String, dynamic> data,
    required String localUserId,
    LocalChatMessage? fallbackMessage,
  }) {
    final conversationId =
        _normalizedString(data['conversationId']) ?? fallbackMessage?.conversationId;

    if (conversationId == null || conversationId.isEmpty) {
      return null;
    }

    final senderUserId =
        _normalizedString(data['senderUserId']) ?? fallbackMessage?.senderUserId;
    final recipientUserId =
        _normalizedString(data['recipientUserId']) ?? fallbackMessage?.recipientUserId;

    String? peerUserId;
    if (senderUserId != null && senderUserId != localUserId) {
      peerUserId = senderUserId;
    } else if (recipientUserId != null && recipientUserId != localUserId) {
      peerUserId = recipientUserId;
    } else {
      peerUserId = _peerFromDirectConversationId(
        conversationId: conversationId,
        localUserId: localUserId,
      );
    }

    if (peerUserId == null || peerUserId.isEmpty) {
      return null;
    }

    return SignalNotificationRoute(
      conversationId: conversationId,
      peerUserId: peerUserId,
      deliveryId: _normalizedString(data['deliveryId']) ?? fallbackMessage?.deliveryId,
    );
  }

  static String? _normalizedString(dynamic value) {
    if (value == null) {
      return null;
    }

    final normalized = value.toString().trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static String? _peerFromDirectConversationId({
    required String conversationId,
    required String localUserId,
  }) {
    const prefix = 'direct_';
    if (!conversationId.startsWith(prefix)) {
      return null;
    }

    final rawParticipants = conversationId.substring(prefix.length).split('__');
    for (final participant in rawParticipants) {
      final normalized = participant.trim();
      if (normalized.isNotEmpty && normalized != localUserId) {
        return normalized;
      }
    }
    return null;
  }
}

class SignalNotificationService {
  SignalNotificationService._();

  static final SignalNotificationService instance = SignalNotificationService._();

  static const String _channelId = 'secure_messages';
  static const String _channelName = 'Secure Messages';
  static const String _channelDescription =
      'Secure encrypted message notifications';

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: _channelDescription,
    importance: Importance.max,
    playSound: true,
  );

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<SignalNotificationRoute> _tapRoutesController =
      StreamController<SignalNotificationRoute>.broadcast();

  bool _foregroundInitialized = false;
  bool _backgroundInitialized = false;
  SignalNotificationRoute? _initialTapRoute;

  Stream<SignalNotificationRoute> get tapRoutes => _tapRoutesController.stream;

  SignalNotificationRoute? takeInitialTapRoute() {
    final route = _initialTapRoute;
    _initialTapRoute = null;
    return route;
  }

  Future<void> initializeForeground() async {
    if (kIsWeb || _foregroundInitialized) {
      return;
    }

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    await _ensureAndroidChannel();

    _foregroundInitialized = true;
    _backgroundInitialized = true;

    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final route = SignalNotificationRoute.fromPayload(
        launchDetails?.notificationResponse?.payload,
      );
      if (route != null) {
        _initialTapRoute = route;
      }
    }
  }

  Future<void> initializeBackground() async {
    if (kIsWeb || _backgroundInitialized) {
      return;
    }

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await _ensureAndroidChannel();

    _backgroundInitialized = true;
  }

  Future<void> showIncomingMessageNotification({
    required String localUserId,
    required LocalChatMessage message,
    required SignalMessageRepository repository,
  }) async {
    if (kIsWeb) {
      return;
    }

    if (message.senderUserId == localUserId) {
      return;
    }

    await initializeBackground();

    final route = SignalNotificationRoute.fromMessage(
      message: message,
      localUserId: localUserId,
    );

    final imageBytes = await _loadNotificationImageBytes(
      message: message,
      repository: repository,
    );

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      styleInformation: imageBytes == null
          ? null
          : BigPictureStyleInformation(
              ByteArrayAndroidBitmap(imageBytes),
              hideExpandedLargeIcon: true,
            ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _plugin.show(
      _notificationId(route),
      'New secure message',
      imageBytes == null
          ? 'Open Cipher Courier to read.'
          : 'New secure image message. Open Cipher Courier to view.',
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: route.toPayload(),
    );
  }

  void dispose() {
    unawaited(_tapRoutesController.close());
  }

  Future<void> _ensureAndroidChannel() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_channel);
  }

  Future<Uint8List?> _loadNotificationImageBytes({
    required LocalChatMessage message,
    required SignalMessageRepository repository,
  }) async {
    final payload =
        SecureImageAttachmentPayload.tryParseFromPlaintext(message.plaintext);
    if (payload == null) {
      return null;
    }

    try {
      return await repository.downloadAndDecryptAttachment(payload);
    } catch (_) {
      return null;
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final route = SignalNotificationRoute.fromPayload(response.payload);
    if (route != null && !_tapRoutesController.isClosed) {
      _tapRoutesController.add(route);
    }
  }

  int _notificationId(SignalNotificationRoute route) {
    return Object.hash(
          route.conversationId,
          route.peerUserId,
          route.deliveryId,
        ) &
        0x7fffffff;
  }
}
