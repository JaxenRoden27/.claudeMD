import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_feature_services.dart';
import '../auth/auth_service.dart';
import '../models/app_bootstrap_state.dart';
import '../signal/encrypted_image_attachment_view.dart';
import '../signal/signal_fcm_coordinator.dart';
import '../signal/signal_message_repository.dart';
import '../signal/signal_models.dart';
import '../signal/signal_notification_service.dart';
import '../signal/signal_service.dart';
import '../dev/developer_blackjack_page.dart';

// Colors and Constants moved from main.dart
const _balticBlue = Color(0xFF33658A);
const _skyReflection = Color(0xFF86BBD8);
const _honeyBronze = Color(0xFFF6AE2D);
const _blazeOrange = Color(0xFFF26419);
const _bgLight = Color(0xFFF7F9FC);
const _surfaceLight = Color(0xFFFFFFFF);
const _textPrimaryLight = Color(0xFF1F2933);
const _textSecondaryLight = Color(0xFF52606D);
const _borderLight = Color(0xFFD9E2EC);
const _bgDark = Color(0xFF111827);
const _surfaceDark = Color(0xFF1F2937);
const _textPrimaryDark = Color(0xFFF9FAFB);
const _textSecondaryDark = Color(0xFFD1D5DB);
const _borderDark = Color(0xFF374151);
const _imageMessagePrefix = '[image] ';
const _groupMessagePrefix = '[group-v1] ';

// AppBootstrapState moved to models/app_bootstrap_state.dart

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.bootstrapState, required this.user});

  final AppBootstrapState bootstrapState;
  final User user;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _forumComposerController =
      TextEditingController();
  final AuthService _authService = AuthService();
  final LocalOptionsService _localOptionsService = LocalOptionsService();
  final ForumsService _forumsService = ForumsService();
  final AppGroupsService _appGroupsService = AppGroupsService();
  final ImagePicker _imagePicker = ImagePicker();

  SignalMessageRepository? _repository;
  SignalFcmCoordinator? _fcmCoordinator;
  StreamSubscription<void>? _repositoryInboxSubscription;
  StreamSubscription<SignalNotificationRoute>? _notificationTapSubscription;
  String? _activeUserId;
  String? _peerUserId;
  AccountQrPayload? _linkedAccount;
  SignalNotificationRoute? _pendingNotificationRoute;
  bool _openingConversationFromNotification = false;

  List<LocalTrustRecord> _allPeers = const <LocalTrustRecord>[];
  LocalOptions _localOptions = LocalOptions.defaults;

  int _selectedTabIndex = 0;
  bool _busy = false;
  String _status = 'Preparing secure messaging workspace...';

  @override
  void initState() {
    super.initState();
    _status =
        widget.bootstrapState.warning ??
        'Welcome, ${widget.user.displayName ?? widget.user.email ?? 'User'}.';
    _activeUserId = widget.user.uid;
    _loadLocalOptions();

    _notificationTapSubscription = SignalNotificationService.instance.tapRoutes
        .listen(_handleNotificationRoute);
    final initialTapRoute = SignalNotificationService.instance
        .takeInitialTapRoute();
    if (initialTapRoute != null) {
      _pendingNotificationRoute = initialTapRoute;
    }

    _initializeSignal();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _forumComposerController.dispose();
    _repositoryInboxSubscription?.cancel();
    _notificationTapSubscription?.cancel();
    _fcmCoordinator?.dispose();
    _repository?.dispose();
    super.dispose();
  }

  Future<void> _loadLocalOptions() async {
    final loaded = await _localOptionsService.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _localOptions = loaded;
    });
  }

  Future<void> _updateLocalOptions(LocalOptions options) async {
    setState(() {
      _localOptions = options;
    });
    await _localOptionsService.save(options);
  }

  String _preferredProfileLabel() {
    final displayName = widget.user.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final email = widget.user.email?.trim();
    if (email != null && email.isNotEmpty) {
      final atIndex = email.indexOf('@');
      if (atIndex > 0) {
        return email.substring(0, atIndex);
      }
      return email;
    }

    return 'User';
  }

  void _handleNotificationRoute(SignalNotificationRoute route) {
    _pendingNotificationRoute = route;
    unawaited(_consumePendingNotificationRoute());
  }

  Future<void> _consumePendingNotificationRoute() async {
    if (!mounted || _repository == null || _openingConversationFromNotification) {
      return;
    }

    final route = _pendingNotificationRoute;
    if (route == null) {
      return;
    }

    _pendingNotificationRoute = null;
    _openingConversationFromNotification = true;
    try {
      await _openConversationForPeer(peerUserId: route.peerUserId);
    } finally {
      _openingConversationFromNotification = false;
    }
  }

  Future<void> _openConversationForPeer({
    required String peerUserId,
    String? preferredLabel,
  }) async {
    final repository = _repository;
    if (!mounted || repository == null) {
      return;
    }

    setState(() {
      _peerUserId = peerUserId;
      _selectedTabIndex = 0;
    });

    final trustRecords = await repository.loadTrustState(peerUserId: peerUserId);
    final peerLabel = _resolvePeerLabel(
      preferredLabel: preferredLabel,
      trustRecords: trustRecords,
      fallbackUserId: peerUserId,
    );

    if (!mounted) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _ChatDetailPage(
          dark: Theme.of(context).brightness == Brightness.dark,
          user: widget.user,
          peerUserId: peerUserId,
          peerLabel: peerLabel,
          repository: repository,
          composerController: _composerController,
          busy: _busy,
          firebaseReady: widget.bootstrapState.firebaseReady,
          status: _status,
          warning: widget.bootstrapState.warning,
          onSend: _sendMessage,
          onSendImage: _sendImageMessage,
          onSync: _syncInbox,
        ),
      ),
    );

    if (mounted) {
      await _reloadLocalState();
    }
  }

  String _resolvePeerLabel({
    required String? preferredLabel,
    required List<LocalTrustRecord> trustRecords,
    required String fallbackUserId,
  }) {
    final preferred = preferredLabel?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return preferred;
    }

    for (final record in trustRecords) {
      final candidate = record.label?.trim();
      if (candidate != null && candidate.isNotEmpty) {
        return candidate;
      }
    }

    return fallbackUserId;
  }

  Future<void> _initializeSignal() async {
    if (!widget.bootstrapState.firebaseReady) return;

    setState(() {
      _busy = true;
      _status = 'Initializing secure messaging for your account...';
    });

    try {
      final repository = SignalMessageRepository.forLocalDevice(
        firestore: FirebaseFirestore.instance,
        localUserId: widget.user.uid,
        localDeviceId: SignalService.defaultDeviceId,
      );

      await repository.registerCurrentDevice(
        profileLabel: _preferredProfileLabel(),
      );

      if (!mounted) {
        repository.dispose();
        return;
      }

      _repositoryInboxSubscription?.cancel();
      _repository?.dispose();

      setState(() {
        _repository = repository;
        _activeUserId = widget.user.uid;
        _status = 'Secure messaging ready.';
      });

      repository.setupRealtimeListener();
      _repositoryInboxSubscription = repository.inboxUpdates.listen((_) {
        _reloadLocalState();
      });

      await _bindForegroundWakeHandler();
      await _reloadLocalState();
      await _consumePendingNotificationRoute();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Signal initialization failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _bindForegroundWakeHandler() async {
    if (!widget.bootstrapState.messagingReady ||
        _repository == null ||
        _activeUserId == null) {
      return;
    }

    _fcmCoordinator?.dispose();
    final coordinator = SignalFcmCoordinator(
      firestore: FirebaseFirestore.instance,
    );
    await coordinator.initializeForeground(
      localUserId: _activeUserId!,
      localDeviceId: SignalService.defaultDeviceId,
      repository: _repository!,
      onMessageSynced: (message) async {
        await _reloadLocalState();
        if (!mounted) {
          return;
        }
        setState(() {
          _status = 'New encrypted message received.';
        });
      },
      onNotificationOpened: (route) async {
        _handleNotificationRoute(route);
      },
    );
    _fcmCoordinator = coordinator;
  }

  Future<void> _reloadLocalState() async {
    final repository = _repository;
    if (repository == null) return;

    final allPeers = await repository.loadAllKnownPeers();

    if (!mounted) return;

    setState(() {
      _allPeers = allPeers;
    });
  }

  Future<void> _syncInbox() async {
    final repository = _repository;
    if (repository == null) {
      if (mounted) {
        setState(() {
          _status = 'Secure messaging not ready.';
        });
      }
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Fetching queued ciphertext...';
    });

    try {
      final imported = await repository.syncPendingMessages(peerUserId: null);
      await _reloadLocalState();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = imported == 0
            ? 'No new messages.'
            : 'Imported $imported new message(s).';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Sync failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _sendMessage() async {
    final repository = _repository;
    final peerUserId = _peerUserId;
    final plaintext = _composerController.text.trim();
    if (repository == null || peerUserId == null || plaintext.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Encrypting and sending message...';
    });

    try {
      await repository.sendTextMessage(
        peerUserId: peerUserId,
        plaintext: plaintext,
      );
      _composerController.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      await _reloadLocalState();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Message sent securely.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Send failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _sendImageMessage() async {
    final repository = _repository;
    final peerUserId = _peerUserId;
    if (repository == null ||
        peerUserId == null ||
        !widget.bootstrapState.firebaseReady) {
      return;
    }

    final selected = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2048,
    );
    if (selected == null) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Uploading and encrypting image...';
    });

    try {
      final bytes = await selected.readAsBytes();
      await repository.sendEncryptedImageMessage(
        peerUserId: peerUserId,
        imageBytes: bytes,
        mimeType: selected.mimeType ?? 'image/jpeg',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await _reloadLocalState();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Image sent securely.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _describeImageUploadError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _scanAccountQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (context) => _AccountQrScannerPage(
          preferredCamera: _localOptions.preferredCamera,
        ),
      ),
    );
    if (raw == null) {
      return;
    }

    final parsed = AccountQrPayload.tryParse(raw);
    if (!mounted) {
      return;
    }
    if (parsed == null) {
      setState(() {
        _status = 'Invalid QR code.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Establishing secure connection with ${parsed.label}...';
    });

    try {
      await _repository?.ensurePeerTrust(
        peerUserId: parsed.userId,
        label: parsed.label,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Failed to link account: $e';
      });
      return;
    }

    if (!mounted) return;

    setState(() {
      _busy = false;
      _linkedAccount = parsed;
      _peerUserId = parsed.userId;
      _status = 'Linked with ${parsed.label}.';
    });

    await _reloadLocalState();
  }

  Future<void> _createForumPost() async {
    final userId = _activeUserId;
    if (userId == null) {
      return;
    }

    final body = _forumComposerController.text.trim();
    if (body.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
    });
    try {
      await _forumsService.createPost(
        authorUserId: userId,
        authorLabel: widget.user.displayName ?? widget.user.email ?? 'User',
        body: body,
      );
      _forumComposerController.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Forum post published.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Failed to publish: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _createGroup({
    required String name,
    List<String> initialMemberUserIds = const <String>[],
  }) async {
    final userId = _activeUserId;
    if (userId == null) {
      return;
    }

    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
    });
    try {
      await _appGroupsService.createGroup(
        createdBy: userId,
        name: trimmedName,
        initialMemberUserIds: initialMemberUserIds,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Group created.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Failed to create group: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _showMyQrCode() {
    final payload = AccountQrPayload(
      userId: widget.user.uid,
      deviceId: SignalService.defaultDeviceId,
      label: widget.user.displayName ?? widget.user.email ?? 'User',
    );
    final rawJson = jsonEncode(payload.toJson());

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('My QR Code'),
          content: SizedBox(
            width: 250,
            height: 250,
            child: Center(
              child: QrImageView(
                data: rawJson,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final userLabel = (widget.user.displayName?.trim().isNotEmpty ?? false)
        ? widget.user.displayName!.trim()
        : (widget.user.email?.trim().isNotEmpty ?? false)
        ? widget.user.email!.trim()
        : 'User';
    final userInitial = userLabel.substring(0, 1).toUpperCase();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            InkWell(
              onTap: _showMyQrCode,
              borderRadius: BorderRadius.circular(16),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: _balticBlue.withValues(alpha: 0.18),
                child: Text(
                  userInitial,
                  style: const TextStyle(
                    color: _balticBlue,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  userLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Cipher Courier',
                  style: TextStyle(
                    fontSize: 12,
                    color: dark ? _textSecondaryDark : _textSecondaryLight,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Sync inbox',
            onPressed:
                widget.bootstrapState.firebaseReady &&
                    !_busy &&
                    _peerUserId != null
                ? _syncInbox
                : null,
            icon: const Icon(Icons.sync_rounded),
          ),
          IconButton(
            tooltip: 'Sign Out',
            onPressed: () => _authService.signOut(),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: <Widget>[
          _ConversationsTab(
            dark: dark,
            user: widget.user,
            status: _status,
            warning: widget.bootstrapState.warning,
            busy: _busy,
            peers: _allPeers,
            onOpenConversation: (LocalTrustRecord peer) {
              _openConversationForPeer(
                peerUserId: peer.userId,
                preferredLabel: peer.label,
              );
            },
            onSync: widget.bootstrapState.firebaseReady && !_busy
                ? _syncInbox
                : null,
          ),
          _ForumsTab(
            dark: dark,
            user: widget.user,
            forumsService: _forumsService,
            composerController: _forumComposerController,
            busy: _busy,
            onCreatePost: _createForumPost,
          ),
          _GroupsTab(
            dark: dark,
            user: widget.user,
            appGroupsService: _appGroupsService,
            repository: _repository,
            busy: _busy,
            onCreateGroup: _createGroup,
            onStatusChange: (message) {
              if (!mounted) {
                return;
              }
              setState(() {
                _status = message;
              });
            },
          ),
          _SettingsTab(
            dark: dark,
            user: widget.user,
            status: _status,
            warning: widget.bootstrapState.warning,
            busy: _busy,
            localOptions: _localOptions,
            linkedAccount: _linkedAccount,
            onSync: widget.bootstrapState.firebaseReady && !_busy
                ? _syncInbox
                : null,
            onScanQr: !_busy ? _scanAccountQr : null,
            onShowQr: _showMyQrCode,
            onToggleAutoSync: (enabled) {
              _updateLocalOptions(
                _localOptions.copyWith(autoSyncEnabled: enabled),
              );
            },
            onToggleMultiDeviceHints: (enabled) {
              _updateLocalOptions(
                _localOptions.copyWith(multiDeviceHints: enabled),
              );
            },
            onSetPreferredCamera: (camera) {
              _updateLocalOptions(
                _localOptions.copyWith(preferredCamera: camera),
              );
            },
            onOpenDeveloperTable: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const DeveloperBlackjackPage(),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum_rounded),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.question_answer_outlined),
            selectedIcon: Icon(Icons.question_answer_rounded),
            label: 'Forums',
          ),
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups_rounded),
            label: 'Groups',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

String _describeImageUploadError(Object error) {
  final raw = error.toString();
  final lowered = raw.toLowerCase();
  if (lowered.contains('terminated the upload session') ||
      lowered.contains('object does not exist') ||
      lowered.contains('not found')) {
    return 'Image upload failed: Storage bucket/session not found. Verify Firebase Storage is enabled, bucket name is correct, and try again.';
  }
  if (lowered.contains('app check') || lowered.contains('appcheckprovider')) {
    return 'Image upload blocked by App Check configuration. Install an App Check provider (or debug provider in dev).';
  }
  if (lowered.contains('permission') || lowered.contains('unauthorized')) {
    return 'Image upload denied by Storage rules. Confirm conversation membership and auth state.';
  }
  return 'Image send failed: $error';
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.busy,
    required this.dark,
    required this.warning,
  });

  final String status;
  final bool busy;
  final bool dark;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.1),
                    )
                  : const Icon(Icons.shield_moon_rounded, color: _balticBlue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: dark ? _textPrimaryDark : _textPrimaryLight,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (warning != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              warning!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _blazeOrange),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _ConversationMetaCard extends StatelessWidget {
  const _ConversationMetaCard({
    required this.dark,
    required this.activeUser,
    required this.peerUserId,
    required this.peerLabel,
    required this.trustRecords,
  });

  final bool dark;
  final User activeUser;
  final String peerUserId;
  final String peerLabel;
  final List<LocalTrustRecord> trustRecords;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Secure chat with $peerLabel',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: dark ? _textPrimaryDark : _textPrimaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  const _MessagesPanel({
    required this.dark,
    required this.repository,
    required this.messages,
    required this.activeUserId,
    required this.peerLabel,
    this.controller,
  });

  final bool dark;
  final SignalMessageRepository repository;
  final List<LocalChatMessage> messages;
  final String? activeUserId;
  final String peerLabel;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: messages.isEmpty
          ? Center(
              child: Text(
                'No messages yet. Link with a peer to start chatting.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: dark ? _textSecondaryDark : _textSecondaryLight,
                ),
              ),
            )
          : ListView.separated(
              controller: controller,
              itemCount: messages.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final message = messages[index];
                final outgoing = message.senderUserId == activeUserId;
                final imageUrl = _extractImageMessageUrl(message.plaintext);
                final secureImage =
                    SecureImageAttachmentPayload.tryParseFromPlaintext(
                      message.plaintext,
                    );
                return Align(
                  alignment: outgoing
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: outgoing
                            ? _balticBlue
                            : dark
                            ? const Color(0xFF334155)
                            : const Color(0xFFEFF4FA),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: outgoing
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              outgoing ? 'You' : peerLabel,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: outgoing
                                        ? _skyReflection
                                        : dark
                                        ? _textSecondaryDark
                                        : _textSecondaryLight,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            if (imageUrl != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  imageUrl,
                                  width: 220,
                                  height: 170,
                                  fit: BoxFit.cover,
                                ),
                              )
                            else if (secureImage != null)
                              EncryptedImageAttachmentView(
                                key: ValueKey<String>(secureImage.attachmentId),
                                repository: repository,
                                payload: secureImage,
                                dark: dark,
                                outgoing: outgoing,
                              )
                            else
                              Text(
                                message.plaintext,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: outgoing
                                          ? Colors.white
                                          : dark
                                          ? _textPrimaryDark
                                          : _textPrimaryLight,
                                      height: 1.35,
                                    ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}  ${message.deliveryState}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: outgoing
                                        ? const Color(0xFFD6E8F7)
                                        : dark
                                        ? _textSecondaryDark
                                        : _textSecondaryLight,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

String? _extractImageMessageUrl(String plaintext) {
  final trimmed = plaintext.trim();
  if (!trimmed.startsWith(_imageMessagePrefix)) {
    return null;
  }

  final candidate = trimmed.substring(_imageMessagePrefix.length).trim();
  if (candidate.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return null;
  }

  return candidate;
}

class _GroupEnvelopePayload {
  const _GroupEnvelopePayload({
    required this.groupId,
    required this.groupMessageId,
    required this.body,
  });

  final String groupId;
  final String groupMessageId;
  final String body;
}

String _encodeGroupEnvelope({
  required String groupId,
  required String groupMessageId,
  required String body,
}) {
  final payload = jsonEncode(<String, dynamic>{
    'groupId': groupId,
    'groupMessageId': groupMessageId,
    'body': body,
  });
  return '$_groupMessagePrefix$payload';
}

_GroupEnvelopePayload? _parseGroupEnvelope(String plaintext) {
  final trimmed = plaintext.trim();
  if (!trimmed.startsWith(_groupMessagePrefix)) {
    return null;
  }

  final payload = trimmed.substring(_groupMessagePrefix.length).trim();
  if (payload.isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final groupId = decoded['groupId'] as String?;
    final groupMessageId = decoded['groupMessageId'] as String?;
    final body = decoded['body'] as String?;

    if (groupId == null ||
        groupId.isEmpty ||
        groupMessageId == null ||
        groupMessageId.isEmpty ||
        body == null ||
        body.isEmpty) {
      return null;
    }

    return _GroupEnvelopePayload(
      groupId: groupId,
      groupMessageId: groupMessageId,
      body: body,
    );
  } catch (_) {
    return null;
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.dark,
    required this.enabled,
    required this.onSend,
    required this.onSendImage,
    this.focusNode,
  });

  final TextEditingController controller;
  final bool dark;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onSendImage;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: enabled ? onSendImage : null,
            tooltip: 'Send image',
            icon: const Icon(Icons.image_outlined),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Type a message',
                border: InputBorder.none,
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          FilledButton.icon(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send'),
          ),
        ],
      ),
    );
  }
}

class _ConversationsTab extends StatelessWidget {
  const _ConversationsTab({
    required this.dark,
    required this.user,
    required this.status,
    required this.warning,
    required this.busy,
    required this.peers,
    required this.onOpenConversation,
    required this.onSync,
  });

  final bool dark;
  final User user;
  final String status;
  final String? warning;
  final bool busy;
  final List<LocalTrustRecord> peers;
  final void Function(LocalTrustRecord)? onOpenConversation;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: dark ? _bgDark : _bgLight,
      child: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _StatusCard(status: status, busy: busy, dark: dark, warning: warning),
                const SizedBox(height: 12),
                Text(
                  'Conversations',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                if (peers.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.inbox),
                      title: Text('No active conversations.'),
                      subtitle: Text('Scan a QR code to securely message a peer.'),
                    ),
                  ),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final peer = peers[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: ListTile(
                      onTap: onOpenConversation != null ? () => onOpenConversation!(peer) : null,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: _honeyBronze.withValues(alpha: 0.18),
                        child: const Icon(Icons.person, color: _honeyBronze),
                      ),
                      title: Text(
                        peer.label ?? 'Unknown Peer',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        'Device: ${peer.deviceId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
                childCount: peers.length,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatDetailPage extends StatefulWidget {
  const _ChatDetailPage({
    required this.dark,
    required this.user,
    required this.peerUserId,
    required this.peerLabel,
    required this.repository,
    required this.composerController,
    required this.busy,
    required this.firebaseReady,
    required this.status,
    required this.warning,
    required this.onSend,
    required this.onSendImage,
    required this.onSync,
  });

  final bool dark;
  final User user;
  final String peerUserId;
  final String peerLabel;
  final SignalMessageRepository repository;
  final TextEditingController composerController;
  final bool busy;
  final bool firebaseReady;
  final String status;
  final String? warning;
  final VoidCallback onSend;
  final VoidCallback onSendImage;
  final VoidCallback onSync;

  @override
  State<_ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<_ChatDetailPage> {
  List<LocalChatMessage> _messages = const [];
  List<LocalTrustRecord> _trustRecords = const [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _loadData();
    _sub = widget.repository.inboxUpdates.listen((_) {
      if (mounted) _loadData();
    });
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _loadData() async {
    final messages = await widget.repository.loadConversationMessages(
      peerUserId: widget.peerUserId,
    );
    final trustRecords = await widget.repository.loadTrustState(
      peerUserId: widget.peerUserId,
    );
    if (mounted) {
      setState(() {
        _messages = messages;
        _trustRecords = trustRecords;
      });
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peerLabel),
        actions: <Widget>[
          IconButton(
            onPressed: widget.busy ? null : widget.onSync,
            icon: const Icon(Icons.sync_rounded),
            tooltip: 'Sync',
          ),
        ],
      ),
      body: Container(
        color: widget.dark ? _bgDark : _bgLight,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _StatusCard(
                  status: widget.status,
                  busy: widget.busy,
                  dark: widget.dark,
                  warning: widget.warning,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _ConversationMetaCard(
                  dark: widget.dark,
                  activeUser: widget.user,
                  peerUserId: widget.peerUserId,
                  peerLabel: widget.peerLabel,
                  trustRecords: _trustRecords,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _MessagesPanel(
                    dark: widget.dark,
                    repository: widget.repository,
                    messages: _messages,
                    activeUserId: widget.user.uid,
                    peerLabel: widget.peerLabel,
                    controller: _scrollController,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: _ComposerBar(
                  controller: widget.composerController,
                  focusNode: _focusNode,
                  dark: widget.dark,
                  enabled: widget.firebaseReady && !widget.busy,
                  onSend: widget.onSend,
                  onSendImage: widget.onSendImage,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForumsTab extends StatefulWidget {
  const _ForumsTab({
    required this.dark,
    required this.user,
    required this.forumsService,
    required this.composerController,
    required this.busy,
    required this.onCreatePost,
  });

  final bool dark;
  final User user;
  final ForumsService forumsService;
  final TextEditingController composerController;
  final bool busy;
  final VoidCallback onCreatePost;

  @override
  State<_ForumsTab> createState() => _ForumsTabState();
}

class _ForumsTabState extends State<_ForumsTab> {
  String? _activeReplyPostId;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.dark ? _bgDark : _bgLight,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          Text(
            'Forums',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: widget.composerController,
                      enabled: !widget.busy,
                      decoration: const InputDecoration(
                        hintText: 'Post to forum',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: !widget.busy ? widget.onCreatePost : null,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<ForumPost>>(
            stream: widget.forumsService.streamLatestPosts(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Forum load failed: ${snapshot.error}'),
                  ),
                );
              }

              final posts = snapshot.data ?? const <ForumPost>[];
              if (posts.isEmpty) {
                return const Card(
                  child: ListTile(
                    leading: Icon(Icons.forum_outlined),
                    title: Text('No forum posts yet'),
                    subtitle: Text('Start the first discussion.'),
                  ),
                );
              }

              return Column(
                children: posts
                    .take(15)
                    .map(
                      (post) => _ForumPostCard(
                        key: ValueKey(post.id),
                        post: post,
                        user: widget.user,
                        forumsService: widget.forumsService,
                        isActive: _activeReplyPostId == post.id,
                        onActivate: () => setState(() => _activeReplyPostId = post.id),
                        onDeactivate: () => setState(() {
                          if (_activeReplyPostId == post.id) {
                            _activeReplyPostId = null;
                          }
                        }),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ForumPostCard extends StatefulWidget {
  const _ForumPostCard({
    super.key,
    required this.post,
    required this.user,
    required this.forumsService,
    required this.isActive,
    required this.onActivate,
    required this.onDeactivate,
  });

  final ForumPost post;
  final User user;
  final ForumsService forumsService;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onDeactivate;

  @override
  State<_ForumPostCard> createState() => _ForumPostCardState();
}

class _ForumPostCardState extends State<_ForumPostCard> {
  final TextEditingController _replyController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void didUpdateWidget(covariant _ForumPostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive) {
      _replyController.clear();
    }
  }

  Future<void> _submitReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty) {
      widget.onDeactivate();
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await widget.forumsService.addReply(
        postId: widget.post.id,
        authorUserId: widget.user.uid,
        authorLabel: widget.user.displayName ?? widget.user.email ?? 'User',
        body: text,
      );
      _replyController.clear();
      widget.onDeactivate();
    } catch (_) {
      // Ignore for MVP
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Parent Post
            Row(
              children: [
                const Icon(Icons.message_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.post.authorLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${widget.post.createdAt.hour.toString().padLeft(2, '0')}:${widget.post.createdAt.minute.toString().padLeft(2, '0')}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(widget.post.body),
            const Divider(height: 24),
            // Replies list
            if (widget.post.replies.isNotEmpty) ...[
              for (final reply in widget.post.replies)
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.reply_rounded, size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(
                            reply.authorLabel,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                          const Spacer(),
                          Text(
                            '${reply.createdAt.hour.toString().padLeft(2, '0')}:${reply.createdAt.minute.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(reply.body, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
            ],
            // Reply composer
            if (widget.isActive)
              Focus(
                onFocusChange: (focused) {
                  if (!focused && _replyController.text.trim().isEmpty) {
                    widget.onDeactivate();
                  }
                },
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _replyController,
                        enabled: !_isSubmitting,
                        decoration: const InputDecoration(
                          hintText: 'Add a reply...',
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        style: const TextStyle(fontSize: 13),
                        onSubmitted: (_) => _submitReply(),
                        autofocus: true,
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.send_rounded, size: 18),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(8),
                      onPressed: _isSubmitting ? null : _submitReply,
                    ),
                  ],
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onActivate,
                  icon: const Icon(Icons.reply_rounded, size: 16),
                  label: const Text('Reply'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(60, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupsTab extends StatelessWidget {
  const _GroupsTab({
    required this.dark,
    required this.user,
    required this.appGroupsService,
    required this.repository,
    required this.busy,
    required this.onCreateGroup,
    required this.onStatusChange,
  });

  final bool dark;
  final User user;
  final AppGroupsService appGroupsService;
  final SignalMessageRepository? repository;
  final bool busy;
  final Future<void> Function({
    required String name,
    List<String> initialMemberUserIds,
  })
  onCreateGroup;
  final ValueChanged<String> onStatusChange;

  Future<void> _showCreateGroupDialog(BuildContext context) async {
    final request = await showDialog<_CreateGroupRequest>(
      context: context,
      builder: (_) => _CreateGroupDialog(
        currentUserId: user.uid,
        appGroupsService: appGroupsService,
      ),
    );
    if (request == null) {
      return;
    }

    try {
      await onCreateGroup(
        name: request.name,
        initialMemberUserIds: request.initialMemberUserIds,
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to create group: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: dark ? _bgDark : _bgLight,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          Text(
            'Groups',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Create a group and choose members.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => _showCreateGroupDialog(context),
                      icon: const Icon(Icons.group_add_rounded),
                      label: const Text('Create Group'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<AppGroup>>(
            stream: appGroupsService.streamGroups(currentUserId: user.uid),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Group load failed: ${snapshot.error}'),
                  ),
                );
              }

              final groups = snapshot.data ?? const <AppGroup>[];
              if (groups.isEmpty) {
                return const Card(
                  child: ListTile(
                    leading: Icon(Icons.groups_rounded),
                    title: Text('No groups yet'),
                  ),
                );
              }

              return Column(
                children: groups
                    .take(15)
                    .map(
                      (group) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) => _GroupDetailPage(
                                  dark: dark,
                                  user: user,
                                  group: group,
                                  appGroupsService: appGroupsService,
                                  repository: repository,
                                  onStatusChange: onStatusChange,
                                ),
                              ),
                            );
                          },
                          leading: const Icon(Icons.group_outlined),
                          title: Text(group.name),
                          subtitle: Text(
                            'Members: ${group.memberCount} • ${group.isOwner(user.uid) ? 'Owner' : 'Participant'}',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CreateGroupRequest {
  const _CreateGroupRequest({
    required this.name,
    required this.initialMemberUserIds,
  });

  final String name;
  final List<String> initialMemberUserIds;
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({
    required this.currentUserId,
    required this.appGroupsService,
  });

  final String currentUserId;
  final AppGroupsService appGroupsService;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedMemberIds = <String>{};
  String? _validationMessage;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _validationMessage = 'Group name is required.';
      });
      return;
    }

    Navigator.of(context).pop(
      _CreateGroupRequest(
        name: name,
        initialMemberUserIds: _selectedMemberIds.toList(growable: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contentHeight = math.min(
      460.0,
      MediaQuery.of(context).size.height * 0.72,
    );

    return AlertDialog(
      title: const Text('Create Group'),
      content: SizedBox(
        width: 420,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Group name'),
              onChanged: (_) {
                if (_validationMessage != null) {
                  setState(() {
                    _validationMessage = null;
                  });
                }
              },
              onSubmitted: (_) => _submit(),
            ),
            if (_validationMessage != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _validationMessage!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Add members now (optional)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<AppUserProfile>>(
                stream: widget.appGroupsService.streamAvailableUsers(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text('Failed to load users: ${snapshot.error}');
                  }

                  final users = (snapshot.data ?? const <AppUserProfile>[])
                      .where(
                        (candidate) => candidate.userId != widget.currentUserId,
                      )
                      .toList(growable: false);

                  if (users.isEmpty) {
                    return const Center(
                      child: Text('No other app users found yet.'),
                    );
                  }

                  return ListView.builder(
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final candidate = users[index];
                      final selected = _selectedMemberIds.contains(
                        candidate.userId,
                      );

                      return CheckboxListTile(
                        dense: true,
                        value: selected,
                        title: Text(
                          candidate.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onChanged: (value) {
                          setState(() {
                            if (value ?? false) {
                              _selectedMemberIds.add(candidate.userId);
                            } else {
                              _selectedMemberIds.remove(candidate.userId);
                            }
                          });
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _GroupDetailPage extends StatefulWidget {
  const _GroupDetailPage({
    required this.dark,
    required this.user,
    required this.group,
    required this.appGroupsService,
    required this.repository,
    required this.onStatusChange,
  });

  final bool dark;
  final User user;
  final AppGroup group;
  final AppGroupsService appGroupsService;
  final SignalMessageRepository? repository;
  final ValueChanged<String> onStatusChange;

  @override
  State<_GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<_GroupDetailPage> {
  final TextEditingController _composerController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  StreamSubscription<List<AppGroupMember>>? _memberSubscription;
  StreamSubscription<void>? _inboxSubscription;
  StreamSubscription<List<AppUserProfile>>? _userProfilesSubscription;

  List<AppGroupMember> _members = const <AppGroupMember>[];
  List<_GroupMessageView> _messages = const <_GroupMessageView>[];
  Map<String, String> _userLabels = const <String, String>{};
  bool _busy = false;
  String? _inlineStatus;

  bool get _isCurrentUserMember {
    return _members.any((member) => member.userId == widget.user.uid);
  }

  bool get _isCurrentUserOwner {
    return _members.any(
      (member) => member.userId == widget.user.uid && member.isOwner,
    );
  }

  @override
  void initState() {
    super.initState();

    _memberSubscription = widget.appGroupsService
        .streamGroupMembers(groupId: widget.group.id)
        .listen((members) {
          if (!mounted) {
            return;
          }
          setState(() {
            _members = members;
          });
          _reloadMessages();
        });

    _inboxSubscription = widget.repository?.inboxUpdates.listen((_) {
      _reloadMessages();
    });

    _userProfilesSubscription = widget.appGroupsService
        .streamAvailableUsers()
        .listen((profiles) {
          if (!mounted) {
            return;
          }

          final mapped = <String, String>{
            for (final profile in profiles) profile.userId: profile.label,
          };
          setState(() {
            _userLabels = mapped;
          });
        });
  }

  @override
  void dispose() {
    _memberSubscription?.cancel();
    _inboxSubscription?.cancel();
    _userProfilesSubscription?.cancel();
    _composerController.dispose();
    super.dispose();
  }

  String _labelForUser(String userId) {
    if (userId == widget.user.uid) {
      return 'You';
    }
    return _userLabels[userId] ?? userId;
  }

  Future<void> _reloadMessages() async {
    final repository = widget.repository;
    if (repository == null) {
      return;
    }

    final memberIds =
        (_members.isEmpty
                ? widget.group.memberUserIds
                : _members.map((member) => member.userId))
            .where((userId) => userId != widget.user.uid)
            .toSet()
            .toList(growable: false);

    if (memberIds.isEmpty) {
      if (mounted) {
        setState(() {
          _messages = const <_GroupMessageView>[];
        });
      }
      return;
    }

    final deduped = <String, _GroupMessageView>{};

    for (final peerUserId in memberIds) {
      final peerMessages = await repository.loadConversationMessages(
        peerUserId: peerUserId,
      );

      for (final localMessage in peerMessages) {
        final payload = _parseGroupEnvelope(localMessage.plaintext);
        if (payload == null || payload.groupId != widget.group.id) {
          continue;
        }

        final candidate = _GroupMessageView(
          groupMessageId: payload.groupMessageId,
          senderUserId: localMessage.senderUserId,
          body: payload.body,
          createdAt: localMessage.createdAt,
          deliveryState: localMessage.deliveryState,
          outgoing: localMessage.senderUserId == widget.user.uid,
        );

        final existing = deduped[payload.groupMessageId];
        if (existing == null ||
            candidate.createdAt.isBefore(existing.createdAt)) {
          deduped[payload.groupMessageId] = candidate;
        }
      }
    }

    final merged = deduped.values.toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (!mounted) {
      return;
    }
    setState(() {
      _messages = merged;
    });
  }

  Future<void> _sendGroupMessage() async {
    final repository = widget.repository;
    if (repository == null) {
      return;
    }

    final text = _composerController.text.trim();
    if (text.isEmpty) {
      return;
    }
    if (!_isCurrentUserMember) {
      _setStatus('You are no longer a member of this group.');
      return;
    }

    final recipients = _members
        .where((member) => member.userId != widget.user.uid)
        .map((member) => member.userId)
        .toSet()
        .toList(growable: false);

    if (recipients.isEmpty) {
      _setStatus('Add at least one other member before sending messages.');
      return;
    }

    setState(() {
      _busy = true;
    });

    final groupMessageId = FirebaseFirestore.instance
        .collection('_group_message_ids')
        .doc()
        .id;
    final payload = _encodeGroupEnvelope(
      groupId: widget.group.id,
      groupMessageId: groupMessageId,
      body: text,
    );

    final failures = <String>[];
    for (final recipientUserId in recipients) {
      try {
        await repository.sendTextMessage(
          peerUserId: recipientUserId,
          plaintext: payload,
        );
      } catch (_) {
        failures.add(recipientUserId);
      }
    }

    _composerController.clear();
    await _reloadMessages();

    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
    });

    if (failures.isEmpty) {
      _setStatus(
        'Sent secure group message to ${recipients.length} member(s).',
      );
    } else {
      _setStatus(
        'Sent with partial failures. Could not deliver to: ${failures.join(', ')}',
      );
    }
  }

  Future<void> _sendGroupImageMessage() async {
    final repository = widget.repository;
    if (repository == null || widget.user.uid.trim().isEmpty) {
      return;
    }
    if (!_isCurrentUserMember) {
      _setStatus('You are no longer a member of this group.');
      return;
    }

    final selected = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2048,
    );
    if (selected == null) {
      return;
    }

    final recipients = _members
        .where((member) => member.userId != widget.user.uid)
        .map((member) => member.userId)
        .toSet()
        .toList(growable: false);
    if (recipients.isEmpty) {
      _setStatus('Add at least one other member before sending images.');
      return;
    }

    final imageBytes = await selected.readAsBytes();
    final groupMessageId = FirebaseFirestore.instance
        .collection('_group_message_ids')
        .doc()
        .id;

    setState(() {
      _busy = true;
    });

    final failures = <String>[];
    for (final recipientUserId in recipients) {
      try {
        await repository.sendEncryptedImageMessage(
          peerUserId: recipientUserId,
          imageBytes: imageBytes,
          mimeType: selected.mimeType ?? 'image/jpeg',
          wrapPlaintext: (payload) => _encodeGroupEnvelope(
            groupId: widget.group.id,
            groupMessageId: groupMessageId,
            body: payload,
          ),
        );
      } catch (_) {
        failures.add(recipientUserId);
      }
    }

    await _reloadMessages();
    if (!mounted) {
      return;
    }

    setState(() {
      _busy = false;
    });

    if (failures.isEmpty) {
      _setStatus('Sent encrypted image to ${recipients.length} member(s).');
    } else {
      _setStatus(
        'Image sent with partial failures. Could not deliver to: ${failures.join(', ')}',
      );
    }
  }

  Future<void> _showAddMembersDialog() async {
    if (!_isCurrentUserMember) {
      return;
    }

    final currentMemberIds = _members.map((member) => member.userId).toSet();
    final selectedUserIds = <String>{};
    var saving = false;
    var completed = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add Members'),
              content: SizedBox(
                width: 420,
                height: math.min(
                  420.0,
                  MediaQuery.of(context).size.height * 0.7,
                ),
                child: StreamBuilder<List<AppUserProfile>>(
                  stream: widget.appGroupsService.streamAvailableUsers(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text('Failed to load users: ${snapshot.error}');
                    }

                    final candidates =
                        (snapshot.data ?? const <AppUserProfile>[])
                            .where(
                              (user) => !currentMemberIds.contains(user.userId),
                            )
                            .toList(growable: false);

                    if (candidates.isEmpty) {
                      return const Text(
                        'There are no additional app users to add.',
                      );
                    }

                    return ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final candidate = candidates[index];
                        final selected = selectedUserIds.contains(
                          candidate.userId,
                        );

                        return CheckboxListTile(
                          dense: true,
                          value: selected,
                          title: Text(
                            candidate.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: saving
                              ? null
                              : (value) {
                                  setDialogState(() {
                                    if (value ?? false) {
                                      selectedUserIds.add(candidate.userId);
                                    } else {
                                      selectedUserIds.remove(candidate.userId);
                                    }
                                  });
                                },
                        );
                      },
                    );
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
                FilledButton(
                  onPressed: saving || selectedUserIds.isEmpty
                      ? null
                      : () async {
                          setDialogState(() {
                            saving = true;
                          });

                          try {
                            for (final userId in selectedUserIds) {
                              await widget.appGroupsService.addMember(
                                groupId: widget.group.id,
                                addedBy: widget.user.uid,
                                memberUserId: userId,
                              );
                            }

                            if (dialogContext.mounted) {
                              completed = true;
                              Navigator.of(dialogContext).pop();
                            }
                            _setStatus(
                              'Added ${selectedUserIds.length} member(s) to the group.',
                            );
                          } catch (error) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Failed to add members: $error',
                                  ),
                                ),
                              );
                            }
                          } finally {
                            if (!completed && dialogContext.mounted) {
                              setDialogState(() {
                                saving = false;
                              });
                            }
                          }
                        },
                  child: const Text('Add Selected'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showMembersSheet() async {
    final canRemoveMembers = _isCurrentUserOwner;
    final canAddMembers = _isCurrentUserMember;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: math.min(
              520.0,
              MediaQuery.of(sheetContext).size.height * 0.78,
            ),
            child: Column(
              children: <Widget>[
                ListTile(
                  title: Text('Members (${_members.length})'),
                  trailing: canAddMembers
                      ? IconButton(
                          tooltip: 'Add members',
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _showAddMembersDialog();
                          },
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                        )
                      : null,
                ),
                const Divider(height: 1),
                Expanded(
                  child: _members.isEmpty
                      ? const Center(child: Text('No members found.'))
                      : ListView.builder(
                          itemCount: _members.length,
                          itemBuilder: (context, index) {
                            final member = _members[index];
                            return ListTile(
                              leading: Icon(
                                member.isOwner
                                    ? Icons.shield_rounded
                                    : Icons.person_outline_rounded,
                              ),
                              title: Text(
                                _labelForUser(member.userId),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(member.roleLabel),
                              trailing: canRemoveMembers && !member.isOwner
                                  ? IconButton(
                                      tooltip: 'Remove member',
                                      onPressed: () =>
                                          _removeMember(member.userId),
                                      icon: const Icon(
                                        Icons.person_remove_rounded,
                                      ),
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _removeMember(String memberUserId) async {
    if (!_isCurrentUserOwner) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove Member'),
          content: Text('Remove $memberUserId from this group?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      await widget.appGroupsService.removeMember(
        groupId: widget.group.id,
        removedBy: widget.user.uid,
        memberUserId: memberUserId,
      );
      _setStatus('Removed $memberUserId from the group.');
    } catch (error) {
      _setStatus('Failed to remove member: $error');
    }
  }

  void _setStatus(String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _inlineStatus = status;
    });
    widget.onStatusChange(status);
  }

  @override
  Widget build(BuildContext context) {
    final canAddMembers = _isCurrentUserMember;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: <Widget>[
          if (canAddMembers)
            IconButton(
              tooltip: 'Add members',
              onPressed: _showAddMembersDialog,
              icon: const Icon(Icons.person_add_alt_1_rounded),
            ),
          IconButton(
            tooltip: 'View members',
            onPressed: _showMembersSheet,
            icon: const Icon(Icons.groups_rounded),
          ),
          IconButton(
            tooltip: 'Refresh group messages',
            onPressed: _reloadMessages,
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: Container(
        color: widget.dark ? _bgDark : _bgLight,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _StatusCard(
                  status:
                      _inlineStatus ??
                      (_isCurrentUserOwner
                          ? 'Owner • ${_members.length} members'
                          : _isCurrentUserMember
                          ? 'Participant • ${_members.length} members'
                          : 'You are not in this group'),
                  busy: _busy,
                  dark: widget.dark,
                  warning: null,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _GroupMessagesPanel(
                    dark: widget.dark,
                    repository: widget.repository,
                    messages: _messages,
                    activeUserId: widget.user.uid,
                    resolveSenderLabel: _labelForUser,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: _GroupComposerBar(
                  controller: _composerController,
                  dark: widget.dark,
                  enabled: !_busy && _isCurrentUserMember,
                  onSend: _sendGroupMessage,
                  onSendImage: _sendGroupImageMessage,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupMessageView {
  const _GroupMessageView({
    required this.groupMessageId,
    required this.senderUserId,
    required this.body,
    required this.createdAt,
    required this.deliveryState,
    required this.outgoing,
  });

  final String groupMessageId;
  final String senderUserId;
  final String body;
  final DateTime createdAt;
  final String deliveryState;
  final bool outgoing;
}

class _GroupMessagesPanel extends StatelessWidget {
  const _GroupMessagesPanel({
    required this.dark,
    required this.repository,
    required this.messages,
    required this.activeUserId,
    required this.resolveSenderLabel,
  });

  final bool dark;
  final SignalMessageRepository? repository;
  final List<_GroupMessageView> messages;
  final String activeUserId;
  final String Function(String userId) resolveSenderLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: messages.isEmpty
          ? Center(
              child: Text(
                'No messages yet. Send one to start this group chat.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: dark ? _textSecondaryDark : _textSecondaryLight,
                ),
              ),
            )
          : ListView.separated(
              itemCount: messages.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final message = messages[index];
                final outgoing = message.senderUserId == activeUserId;
                final secureImage =
                    SecureImageAttachmentPayload.tryParseFromPlaintext(
                      message.body,
                    );

                return Align(
                  alignment: outgoing
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: outgoing
                            ? _balticBlue
                            : dark
                            ? const Color(0xFF334155)
                            : const Color(0xFFEFF4FA),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: outgoing
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              outgoing
                                  ? 'You'
                                  : resolveSenderLabel(message.senderUserId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: outgoing
                                        ? _skyReflection
                                        : dark
                                        ? _textSecondaryDark
                                        : _textSecondaryLight,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            if (secureImage != null)
                              EncryptedImageAttachmentView(
                                key: ValueKey<String>(secureImage.attachmentId),
                                repository: repository,
                                payload: secureImage,
                                dark: dark,
                                outgoing: outgoing,
                              )
                            else
                              Text(
                                message.body,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: outgoing
                                          ? Colors.white
                                          : dark
                                          ? _textPrimaryDark
                                          : _textPrimaryLight,
                                      height: 1.35,
                                    ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}  ${message.deliveryState}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: outgoing
                                        ? const Color(0xFFD6E8F7)
                                        : dark
                                        ? _textSecondaryDark
                                        : _textSecondaryLight,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _GroupComposerBar extends StatelessWidget {
  const _GroupComposerBar({
    required this.controller,
    required this.dark,
    required this.enabled,
    required this.onSend,
    required this.onSendImage,
  });

  final TextEditingController controller;
  final bool dark;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onSendImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? _surfaceDark : _surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? _borderDark : _borderLight),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: enabled ? onSendImage : null,
            tooltip: 'Send image',
            icon: const Icon(Icons.image_outlined),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Type a message',
                border: InputBorder.none,
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          FilledButton.icon(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send'),
          ),
        ],
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({
    required this.dark,
    required this.user,
    required this.status,
    required this.warning,
    required this.busy,
    required this.localOptions,
    required this.linkedAccount,
    required this.onSync,
    required this.onScanQr,
    required this.onShowQr,
    required this.onToggleAutoSync,
    required this.onToggleMultiDeviceHints,
    required this.onSetPreferredCamera,
    required this.onOpenDeveloperTable,
  });

  final bool dark;
  final User user;
  final String status;
  final String? warning;
  final bool busy;
  final LocalOptions localOptions;
  final AccountQrPayload? linkedAccount;
  final VoidCallback? onSync;
  final VoidCallback? onScanQr;
  final VoidCallback? onShowQr;
  final ValueChanged<bool> onToggleAutoSync;
  final ValueChanged<bool> onToggleMultiDeviceHints;
  final ValueChanged<String> onSetPreferredCamera;
  final VoidCallback onOpenDeveloperTable;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: dark ? _bgDark : _bgLight,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            height: 30,
            child: Stack(
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onOpenDeveloperTable,
                    child: const SizedBox(width: 26, height: 26),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _StatusCard(status: status, busy: busy, dark: dark, warning: warning),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Logged in as: ${user.email}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'UID: ${user.uid}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _ActionButton(
                label: 'Sync',
                icon: Icons.sync_rounded,
                onPressed: onSync,
              ),
              _ActionButton(
                label: 'Scan Peer QR',
                icon: Icons.qr_code_scanner_rounded,
                onPressed: onScanQr,
              ),
              _ActionButton(
                label: 'Show My QR',
                icon: Icons.qr_code_rounded,
                onPressed: onShowQr,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: <Widget>[
                SwitchListTile.adaptive(
                  title: const Text('Auto-sync messages'),
                  value: localOptions.autoSyncEnabled,
                  onChanged: busy ? null : onToggleAutoSync,
                ),
                SwitchListTile.adaptive(
                  title: const Text('Show multi-device hints'),
                  value: localOptions.multiDeviceHints,
                  onChanged: busy ? null : onToggleMultiDeviceHints,
                ),
                ListTile(
                  title: const Text('Preferred scanner camera'),
                  trailing: DropdownButton<String>(
                    value: localOptions.preferredCamera,
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) {
                              onSetPreferredCamera(value);
                            }
                          },
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: 'rear',
                        child: Text('Rear'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'front',
                        child: Text('Front'),
                      ),
                    ],
                  ),
                ),
                if (linkedAccount != null)
                  ListTile(
                    leading: const Icon(Icons.devices_other_rounded),
                    title: Text(linkedAccount!.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountQrScannerPage extends StatefulWidget {
  const _AccountQrScannerPage({required this.preferredCamera});

  final String preferredCamera;

  @override
  State<_AccountQrScannerPage> createState() => _AccountQrScannerPageState();
}

class _AccountQrScannerPageState extends State<_AccountQrScannerPage> {
  late final MobileScannerController _controller;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      facing: widget.preferredCamera == 'front'
          ? CameraFacing.front
          : CameraFacing.back,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan account QR')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_finished) {
            return;
          }

          final barcode = capture.barcodes.isNotEmpty
              ? capture.barcodes.first
              : null;
          final value = barcode?.rawValue;
          if (value == null || value.isEmpty) {
            return;
          }

          _finished = true;
          Navigator.of(context).pop(value);
        },
      ),
    );
  }
}
