import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_feature_services.dart';
import 'auth_service.dart';
import 'firebase_options.dart';
import 'signal/signal_fcm_coordinator.dart';
import 'signal/signal_message_repository.dart';
import 'signal/signal_models.dart';
import 'signal/signal_service.dart';

// Colors and Constants moved from main.dart or localized here
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

class AppBootstrapState {
  const AppBootstrapState({
    required this.firebaseReady,
    required this.messagingReady,
    this.warning,
  });

  const AppBootstrapState.firebaseUnavailable()
    : firebaseReady = false,
      messagingReady = false,
      warning = 'Firebase is not available on this build.';

  final bool firebaseReady;
  final bool messagingReady;
  final String? warning;
}

class SignalChatPage extends StatefulWidget {
  const SignalChatPage({
    super.key,
    required this.bootstrapState,
    required this.user,
  });

  final AppBootstrapState bootstrapState;
  final User user;

  @override
  State<SignalChatPage> createState() => _SignalChatPageState();
}

class _SignalChatPageState extends State<SignalChatPage> {
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _forumComposerController =
      TextEditingController();
  final TextEditingController _groupNameController = TextEditingController();
  final AuthService _authService = AuthService();
  final LocalOptionsService _localOptionsService = LocalOptionsService();
  final ForumsService _forumsService = ForumsService();
  final AppGroupsService _appGroupsService = AppGroupsService();
  final ImagePicker _imagePicker = ImagePicker();

  SignalMessageRepository? _repository;
  SignalFcmCoordinator? _fcmCoordinator;
  String? _activeUserId;
  String? _peerUserId;
  AccountQrPayload? _linkedAccount;

  List<LocalChatMessage> _messages = const <LocalChatMessage>[];
  List<LocalTrustRecord> _trustRecords = const <LocalTrustRecord>[];
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
    _initializeSignal();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _forumComposerController.dispose();
    _groupNameController.dispose();
    _fcmCoordinator?.dispose();
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

      // Register device if not already registered (local-only check inside registerCurrentDevice usually)
      await repository.registerCurrentDevice();

      setState(() {
        _repository = repository;
        _activeUserId = widget.user.uid;
        _status = 'Secure messaging ready.';
      });

      await _bindForegroundWakeHandler();
      await _reloadLocalState();
    } catch (e) {
      setState(() {
        _status = 'Signal initialization failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
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
    );
    _fcmCoordinator = coordinator;
  }

  Future<void> _reloadLocalState() async {
    final repository = _repository;
    final peerUserId = _peerUserId;
    if (repository == null || peerUserId == null) {
      return;
    }

    final messages = await repository.loadConversationMessages(
      peerUserId: peerUserId,
    );
    final trustRecords = await repository.loadTrustState(
      peerUserId: peerUserId,
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _messages = messages;
      _trustRecords = trustRecords;
    });
  }

  Future<void> _syncInbox() async {
    final repository = _repository;
    if (repository == null) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Fetching queued ciphertext...';
    });

    try {
      final imported = await repository.syncPendingMessages(
        peerUserId: _peerUserId,
      );
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
    final activeUserId = _activeUserId;
    if (repository == null ||
        peerUserId == null ||
        activeUserId == null ||
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
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${selected.name}';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('chat_uploads')
          .child(activeUserId)
          .child(fileName);

      await storageRef.putData(
        bytes,
        SettableMetadata(
          contentType: selected.mimeType ?? 'application/octet-stream',
        ),
      );
      final imageUrl = await storageRef.getDownloadURL();
      await repository.sendTextMessage(
        peerUserId: peerUserId,
        plaintext: '[image] $imageUrl',
      );
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
        _status = 'Image send failed: $error';
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

  Future<void> _createGroup() async {
    final userId = _activeUserId;
    if (userId == null) {
      return;
    }

    final name = _groupNameController.text.trim();
    if (name.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
    });
    try {
      await _appGroupsService.createGroup(createdBy: userId, name: name);
      _groupNameController.clear();
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

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final canOpenChat =
        widget.bootstrapState.firebaseReady && _peerUserId != null;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: _balticBlue.withValues(alpha: 0.18),
              child: Text(
                (widget.user.displayName ?? widget.user.email ?? 'U').substring(0, 1).toUpperCase(),
                style: const TextStyle(
                  color: _balticBlue,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.user.displayName ?? widget.user.email ?? 'User',
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
            onPressed: widget.bootstrapState.firebaseReady && !_busy
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
            messageCount: _messages.length,
            lastMessage: _messages.isEmpty ? null : _messages.last,
            peerUserId: _peerUserId,
            onOpenConversation: canOpenChat
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => _ChatDetailPage(
                          dark: dark,
                          user: widget.user,
                          peerUserId: _peerUserId!,
                          trustRecords: _trustRecords,
                          messages: _messages,
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
                  }
                : null,
            onSync: widget.bootstrapState.firebaseReady && !_busy
                ? _syncInbox
                : null,
          ),
          _ContactsTab(
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
            groupNameController: _groupNameController,
            busy: _busy,
            onCreateGroup: _createGroup,
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
            icon: Icon(Icons.people_alt_outlined),
            selectedIcon: Icon(Icons.people_alt_rounded),
            label: 'Contacts',
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
    required this.trustRecords,
  });

  final bool dark;
  final User activeUser;
  final String peerUserId;
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
            'Secure chat with $peerUserId',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: dark ? _textPrimaryDark : _textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Conversation ID: ${SignalMessageRepository.directConversationId(activeUser.uid, peerUserId)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: dark ? _textSecondaryDark : _textSecondaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            trustRecords.isEmpty
                ? 'No trust snapshots yet.'
                : 'Known peer device fingerprints: ${trustRecords.map((record) => '${record.deviceId}:${record.identityKeyHash.substring(0, 10)}').join('  ')}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: dark ? _textSecondaryDark : _textSecondaryLight,
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
    required this.messages,
    required this.activeUserId,
    required this.peerLabel,
  });

  final bool dark;
  final List<LocalChatMessage> messages;
  final String? activeUserId;
  final String peerLabel;

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
              itemCount: messages.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final message = messages[index];
                final outgoing = message.senderUserId == activeUserId;
                final imageUrl = _extractImageMessageUrl(message.plaintext);
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
                                )
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

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
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

class _ConversationsTab extends StatelessWidget {
  const _ConversationsTab({
    required this.dark,
    required this.user,
    required this.status,
    required this.warning,
    required this.busy,
    required this.messageCount,
    required this.lastMessage,
    required this.peerUserId,
    required this.onOpenConversation,
    required this.onSync,
  });

  final bool dark;
  final User user;
  final String status;
  final String? warning;
  final bool busy;
  final int messageCount;
  final LocalChatMessage? lastMessage;
  final String? peerUserId;
  final VoidCallback? onOpenConversation;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final subtitle = lastMessage == null
        ? 'No messages yet.'
        : lastMessage!.plaintext;
    final timestamp = lastMessage == null
        ? 'now'
        : '${lastMessage!.createdAt.hour.toString().padLeft(2, '0')}:${lastMessage!.createdAt.minute.toString().padLeft(2, '0')}';

    return Container(
      color: dark ? _bgDark : _bgLight,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: <Widget>[
          _StatusCard(status: status, busy: busy, dark: dark, warning: warning),
          const SizedBox(height: 12),
          Text(
            'Conversations',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (peerUserId != null)
            Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: ListTile(
                onTap: onOpenConversation,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                leading: CircleAvatar(
                  backgroundColor: _honeyBronze.withValues(alpha: 0.18),
                  child: const Icon(Icons.person, color: _honeyBronze),
                ),
                title: Text(
                  'Peer: $peerUserId',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      timestamp,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 6),
                    if (messageCount > 0)
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: _blazeOrange,
                        child: Text(
                          '$messageCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            const Card(
              child: ListTile(
                leading: Icon(Icons.qr_code_scanner_rounded),
                title: Text('No active conversations'),
                subtitle: Text('Use the Settings tab to link with a peer.'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatDetailPage extends StatelessWidget {
  const _ChatDetailPage({
    required this.dark,
    required this.user,
    required this.peerUserId,
    required this.trustRecords,
    required this.messages,
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
  final List<LocalTrustRecord> trustRecords;
  final List<LocalChatMessage> messages;
  final TextEditingController composerController;
  final bool busy;
  final bool firebaseReady;
  final String status;
  final String? warning;
  final VoidCallback onSend;
  final VoidCallback onSendImage;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Chat: $peerUserId'),
        actions: <Widget>[
          IconButton(
            onPressed: busy ? null : onSync,
            icon: const Icon(Icons.sync_rounded),
            tooltip: 'Sync',
          ),
        ],
      ),
      body: Container(
        color: dark ? _bgDark : _bgLight,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _StatusCard(
                  status: status,
                  busy: busy,
                  dark: dark,
                  warning: warning,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _ConversationMetaCard(
                  dark: dark,
                  activeUser: user,
                  peerUserId: peerUserId,
                  trustRecords: trustRecords,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _MessagesPanel(
                    dark: dark,
                    messages: messages,
                    activeUserId: user.uid,
                    peerLabel: 'Peer',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: _ComposerBar(
                  controller: composerController,
                  dark: dark,
                  enabled: firebaseReady && !busy,
                  onSend: onSend,
                  onSendImage: onSendImage,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactsTab extends StatelessWidget {
  const _ContactsTab({
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
  Widget build(BuildContext context) {
    return Container(
      color: dark ? _bgDark : _bgLight,
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
                      controller: composerController,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        hintText: 'Post to forum',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: !busy ? onCreatePost : null,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<ForumPost>>(
            stream: forumsService.streamLatestPosts(),
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
                      (post) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const Icon(Icons.message_outlined),
                          title: Text(post.authorLabel),
                          subtitle: Text(post.body),
                          trailing: Text(
                            '${post.createdAt.hour.toString().padLeft(2, '0')}:${post.createdAt.minute.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
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

class _GroupsTab extends StatelessWidget {
  const _GroupsTab({
    required this.dark,
    required this.user,
    required this.appGroupsService,
    required this.groupNameController,
    required this.busy,
    required this.onCreateGroup,
  });

  final bool dark;
  final User user;
  final AppGroupsService appGroupsService;
  final TextEditingController groupNameController;
  final bool busy;
  final VoidCallback onCreateGroup;

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
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: groupNameController,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        hintText: 'New group name',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: !busy ? onCreateGroup : null,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<AppGroup>>(
            stream: appGroupsService.streamGroups(),
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
                          leading: const Icon(Icons.group_outlined),
                          title: Text(group.name),
                          subtitle: Text('Members: ${group.memberCount}'),
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
    required this.onToggleAutoSync,
    required this.onToggleMultiDeviceHints,
    required this.onSetPreferredCamera,
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
  final ValueChanged<bool> onToggleAutoSync;
  final ValueChanged<bool> onToggleMultiDeviceHints;
  final ValueChanged<String> onSetPreferredCamera;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: dark ? _bgDark : _bgLight,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          Text(
            'Settings',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
                  Text('UID: ${user.uid}', style: Theme.of(context).textTheme.bodySmall),
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
                    subtitle: Text(
                      'User ${linkedAccount!.userId} / Device ${linkedAccount!.deviceId}',
                    ),
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
