import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_feature_services.dart';
import 'demo_auth_service.dart';
import 'firebase_options.dart';
import 'signal/signal_fcm_coordinator.dart';
import 'signal/signal_message_repository.dart';
import 'signal/signal_models.dart';
import 'signal/signal_service.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return _MyApp();
  }
}

class _MyApp extends StatelessWidget {
  _MyApp({Future<_AppBootstrapState>? bootstrapFuture})
    : _bootstrapFuture = bootstrapFuture ?? _bootstrapApplication();

  final Future<_AppBootstrapState> _bootstrapFuture;

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.light(useMaterial3: true);
    final darkBase = ThemeData.dark(useMaterial3: true);

    return MaterialApp(
      title: 'Cipher Courier',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        colorScheme: const ColorScheme.light(
          primary: _balticBlue,
          secondary: _blazeOrange,
          tertiary: _honeyBronze,
          surface: _surfaceLight,
          onSurface: _textPrimaryLight,
          onPrimary: Colors.white,
        ),
        scaffoldBackgroundColor: _bgLight,
        textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme),
      ),
      darkTheme: darkBase.copyWith(
        colorScheme: const ColorScheme.dark(
          primary: _honeyBronze,
          secondary: _blazeOrange,
          tertiary: _skyReflection,
          surface: _surfaceDark,
          onSurface: _textPrimaryDark,
          onPrimary: _bgDark,
        ),
        scaffoldBackgroundColor: _bgDark,
        textTheme: GoogleFonts.spaceGroteskTextTheme(darkBase.textTheme),
      ),
      themeMode: ThemeMode.system,
      home: FutureBuilder<_AppBootstrapState>(
        future: _bootstrapFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _BootstrapLoadingPage();
          }

          return _SignalChatPage(
            bootstrapState:
                snapshot.data ?? const _AppBootstrapState.firebaseUnavailable(),
          );
        },
      ),
    );
  }
}

Future<_AppBootstrapState> _bootstrapApplication() async {
  String? warning;
  var firebaseReady = false;
  var messagingReady = false;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    _configureFirebaseEmulatorIfRequested();
    firebaseReady = true;
  } catch (error) {
    warning = 'Firebase setup issue: $error';
  }

  if (firebaseReady && _supportsMessagingOnCurrentPlatform) {
    try {
      FirebaseMessaging.onBackgroundMessage(signalFcmBackgroundHandler);
      messagingReady = true;
    } catch (error) {
      warning = _appendWarning(
        warning,
        'Wake-only push handling is unavailable on this platform: $error',
      );
    }
  } else if (firebaseReady) {
    warning = _appendWarning(
      warning,
      'Wake-only FCM is only enabled on Android and iOS builds.',
    );
  }

  return _AppBootstrapState(
    firebaseReady: firebaseReady,
    messagingReady: messagingReady,
    warning: warning,
  );
}

void _configureFirebaseEmulatorIfRequested() {
  const useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');
  if (!useEmulator) {
    return;
  }

  FirebaseFirestore.instance.useFirestoreEmulator('127.0.0.1', 8080);
  FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 9099);
}

bool get _supportsMessagingOnCurrentPlatform {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

String _appendWarning(String? current, String next) {
  if (current == null || current.isEmpty) {
    return next;
  }
  return '$current\n$next';
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

class _AppBootstrapState {
  const _AppBootstrapState({
    required this.firebaseReady,
    required this.messagingReady,
    this.warning,
  });

  const _AppBootstrapState.firebaseUnavailable()
    : firebaseReady = false,
      messagingReady = false,
      warning = 'Firebase is not available on this build.';

  final bool firebaseReady;
  final bool messagingReady;
  final String? warning;
}

class _DemoProfile {
  const _DemoProfile({
    required this.alias,
    required this.label,
    required this.peerAlias,
    required this.email,
    required this.password,
    required this.accent,
  });

  final String alias;
  final String label;
  final String peerAlias;
  final String email;
  final String password;
  final Color accent;
}

const _aliceProfile = _DemoProfile(
  alias: 'alice',
  label: 'Alice',
  peerAlias: 'bob',
  email: 'alice.demo@ciphercourier.app',
  password: 'CipherCourierDemo123!',
  accent: _balticBlue,
);

const _bobProfile = _DemoProfile(
  alias: 'bob',
  label: 'Bob',
  peerAlias: 'alice',
  email: 'bob.demo@ciphercourier.app',
  password: 'CipherCourierDemo123!',
  accent: _blazeOrange,
);

const _profiles = <_DemoProfile>[_aliceProfile, _bobProfile];

class _SignalChatPage extends StatefulWidget {
  const _SignalChatPage({required this.bootstrapState});

  final _AppBootstrapState bootstrapState;

  @override
  State<_SignalChatPage> createState() => _SignalChatPageState();
}

class _SignalChatPageState extends State<_SignalChatPage> {
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _forumComposerController =
      TextEditingController();
  final TextEditingController _groupNameController = TextEditingController();
  final DemoAuthService _authService = DemoAuthService();
  final LocalOptionsService _localOptionsService = LocalOptionsService();
  final ForumsService _forumsService = ForumsService();
  final AppGroupsService _appGroupsService = AppGroupsService();
  final ImagePicker _imagePicker = ImagePicker();

  _DemoProfile _activeProfile = _aliceProfile;
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

  _DemoProfile get _activePeerProfile => _profiles.firstWhere(
    (profile) => profile.alias == _activeProfile.peerAlias,
  );

  @override
  void initState() {
    super.initState();
    _status =
        widget.bootstrapState.warning ??
        'Provision the demo profiles, then send messages with on-device decryption.';
    _loadLocalOptions();
    _activateProfile(_activeProfile, syncAfterSwitch: false);
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

  Future<void> _activateProfile(
    _DemoProfile profile, {
    bool syncAfterSwitch = true,
  }) async {
    setState(() {
      _activeProfile = profile;
      _repository = null;
      _activeUserId = null;
      _peerUserId = null;
      _messages = const <LocalChatMessage>[];
      _trustRecords = const <LocalTrustRecord>[];
      _status =
          widget.bootstrapState.warning ??
          'Signing ${profile.label} in with Firebase Auth...';
    });

    SignalMessageRepository? repository;
    if (widget.bootstrapState.firebaseReady) {
      try {
        final session = await _authService.signInAndResolvePeer(
          DemoAuthProfile(
            alias: profile.alias,
            label: profile.label,
            peerAlias: profile.peerAlias,
            email: profile.email,
            password: profile.password,
          ),
        );

        repository = SignalMessageRepository.forLocalDevice(
          firestore: FirebaseFirestore.instance,
          localUserId: session.userId,
          localDeviceId: SignalService.defaultDeviceId,
        );

        if (!mounted) {
          return;
        }
        setState(() {
          _repository = repository;
          _activeUserId = session.userId;
          _peerUserId = session.peerUserId;
          _status =
              widget.bootstrapState.warning ??
              (session.peerUserId == null
                  ? 'Active profile: ${profile.label}. Provision both demo accounts before sending messages.'
                  : 'Active profile: ${profile.label}. Register or sync to load local chat state.');
        });
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _status = 'Failed to sign ${profile.label} in: $error';
        });
        return;
      }
    }

    await _bindForegroundWakeHandler();
    await _reloadLocalState();

    if (syncAfterSwitch && repository != null) {
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
              ? '${profile.label} is up to date.'
              : 'Synced $imported encrypted delivery record(s) for ${profile.label}.';
        });
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _status = 'Sync skipped for ${profile.label}: $error';
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
          _status =
              'Wake signal fetched a new encrypted message for ${_activeProfile.label}.';
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

  Future<void> _registerActiveProfile() async {
    final repository = _repository;
    final activeUserId = _activeUserId;
    if (repository == null || activeUserId == null) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Registering ${_activeProfile.label} with local Signal keys...';
    });

    try {
      await repository.registerCurrentDevice();
      await _reloadLocalState();
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            '${_activeProfile.label} is registered as $activeUserId with a local-only private key.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Registration failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _provisionBothProfiles() async {
    if (!widget.bootstrapState.firebaseReady) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Provisioning Alice and Bob with separate device bundles...';
    });

    try {
      final originalProfile = _activeProfile;
      for (final profile in _profiles) {
        final session = await _authService.signInAndResolvePeer(
          DemoAuthProfile(
            alias: profile.alias,
            label: profile.label,
            peerAlias: profile.peerAlias,
            email: profile.email,
            password: profile.password,
          ),
        );
        final repository = SignalMessageRepository.forLocalDevice(
          firestore: FirebaseFirestore.instance,
          localUserId: session.userId,
          localDeviceId: SignalService.defaultDeviceId,
        );
        await repository.registerCurrentDevice();
      }

      await _activateProfile(originalProfile, syncAfterSwitch: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Both demo profiles are ready. Send from one profile, switch, then sync the other.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Provisioning failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _syncInbox() async {
    final repository = _repository;
    if (repository == null) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Fetching queued ciphertext for ${_activeProfile.label}...';
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
            ? 'No new ciphertext deliveries for ${_activeProfile.label}.'
            : 'Imported $imported new message(s) for ${_activeProfile.label}.';
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
      _status =
          'Encrypting and fanning out this message to ${_activeProfile.peerAlias} device(s)...';
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
        _status =
            'Message encrypted locally, uploaded as per-device ciphertext, and cached in the local encrypted DB.';
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
      _status = 'Uploading image and wrapping it in encrypted delivery...';
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
        _status = 'Shared image link as encrypted message payload.';
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

  Future<void> _signInWithGoogle() async {
    setState(() {
      _busy = true;
      _status = 'Starting Google sign-in...';
    });

    try {
      final credential = await _authService.signInWithGoogle();
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Google auth successful for ${credential.user?.email ?? credential.user?.uid ?? 'unknown user'}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Google sign-in failed: $error';
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
        _status = 'Scanned QR was not a valid account payload.';
      });
      return;
    }

    setState(() {
      _linkedAccount = parsed;
      _status =
          'Linked account hint: ${parsed.label} (${parsed.userId}/${parsed.deviceId}).';
    });
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
        authorLabel: _activeProfile.label,
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
        _status = 'Failed to publish forum post: $error';
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
    final activePeer = _activePeerProfile;
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
              backgroundColor: _activeProfile.accent.withValues(alpha: 0.18),
              child: Text(
                _activeProfile.label.substring(0, 1),
                style: TextStyle(
                  color: _activeProfile.accent,
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
                  _activeProfile.label,
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
            tooltip: 'Open chat',
            onPressed: canOpenChat
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => _ChatDetailPage(
                          dark: dark,
                          activeProfile: _activeProfile,
                          peerProfile: activePeer,
                          trustRecords: _trustRecords,
                          activeUserId: _activeUserId,
                          peerUserId: _peerUserId,
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
            icon: const Icon(Icons.chat_bubble_rounded),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: <Widget>[
          _ConversationsTab(
            dark: dark,
            activeProfile: _activeProfile,
            peerProfile: activePeer,
            status: _status,
            warning: widget.bootstrapState.warning,
            busy: _busy,
            messageCount: _messages.length,
            lastMessage: _messages.isEmpty ? null : _messages.last,
            onOpenConversation: canOpenChat
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => _ChatDetailPage(
                          dark: dark,
                          activeProfile: _activeProfile,
                          peerProfile: activePeer,
                          trustRecords: _trustRecords,
                          activeUserId: _activeUserId,
                          peerUserId: _peerUserId,
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
            onRegister: widget.bootstrapState.firebaseReady && !_busy
                ? _registerActiveProfile
                : null,
            onProvisionBoth: widget.bootstrapState.firebaseReady && !_busy
                ? _provisionBothProfiles
                : null,
          ),
          _ContactsTab(
            dark: dark,
            activeProfile: _activeProfile,
            peerProfile: activePeer,
            forumsService: _forumsService,
            activeUserId: _activeUserId,
            composerController: _forumComposerController,
            busy: _busy,
            onCreatePost: _createForumPost,
          ),
          _GroupsTab(
            dark: dark,
            activeProfile: _activeProfile,
            appGroupsService: _appGroupsService,
            activeUserId: _activeUserId,
            groupNameController: _groupNameController,
            busy: _busy,
            onCreateGroup: _createGroup,
          ),
          _SettingsTab(
            dark: dark,
            activeProfile: _activeProfile,
            status: _status,
            warning: widget.bootstrapState.warning,
            busy: _busy,
            localOptions: _localOptions,
            linkedAccount: _linkedAccount,
            onRegister: widget.bootstrapState.firebaseReady && !_busy
                ? _registerActiveProfile
                : null,
            onSync: widget.bootstrapState.firebaseReady && !_busy
                ? _syncInbox
                : null,
            onProvisionBoth: widget.bootstrapState.firebaseReady && !_busy
                ? _provisionBothProfiles
                : null,
            onGoogleSignIn: !_busy ? _signInWithGoogle : null,
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
            onSelectProfile: (profile) {
              if (_busy || profile == _activeProfile) {
                return;
              }
              _activateProfile(
                profile,
                syncAfterSwitch: _localOptions.autoSyncEnabled,
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
    required this.activeProfile,
    required this.peerProfile,
    required this.trustRecords,
    required this.activeUserId,
    required this.peerUserId,
  });

  final bool dark;
  final _DemoProfile activeProfile;
  final _DemoProfile peerProfile;
  final List<LocalTrustRecord> trustRecords;
  final String? activeUserId;
  final String? peerUserId;

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
            '${activeProfile.label} chatting with ${peerProfile.label}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: dark ? _textPrimaryDark : _textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            activeUserId == null || peerUserId == null
                ? 'Conversation ID will appear after both demo users sign in.'
                : 'Conversation ID: ${SignalMessageRepository.directConversationId(activeUserId!, peerUserId!)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: dark ? _textSecondaryDark : _textSecondaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            trustRecords.isEmpty
                ? 'No trust snapshots yet. They are stored after bundle fetch or receive.'
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
                'No local transcript yet. Register the profiles, send a message, then sync the recipient profile.',
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
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      width: 220,
                                      height: 90,
                                      alignment: Alignment.center,
                                      color: outgoing
                                          ? const Color(0xFF2A5677)
                                          : const Color(0xFFE2E8F0),
                                      child: Text(
                                        'Image unavailable',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: outgoing
                                                  ? Colors.white
                                                  : _textPrimaryLight,
                                            ),
                                      ),
                                    );
                                  },
                                ),
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
    required this.activeProfile,
    required this.peerProfile,
    required this.status,
    required this.warning,
    required this.busy,
    required this.messageCount,
    required this.lastMessage,
    required this.onOpenConversation,
    required this.onRegister,
    required this.onProvisionBoth,
  });

  final bool dark;
  final _DemoProfile activeProfile;
  final _DemoProfile peerProfile;
  final String status;
  final String? warning;
  final bool busy;
  final int messageCount;
  final LocalChatMessage? lastMessage;
  final VoidCallback? onOpenConversation;
  final VoidCallback? onRegister;
  final VoidCallback? onProvisionBoth;

  @override
  Widget build(BuildContext context) {
    final subtitle = lastMessage == null
        ? 'No messages yet. Register and send your first secure message.'
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
          Row(
            children: <Widget>[
              Expanded(
                child: _ActionButton(
                  label: 'Register ${activeProfile.label}',
                  icon: Icons.key_rounded,
                  onPressed: onRegister,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: 'Provision Both',
                  icon: Icons.devices_rounded,
                  onPressed: onProvisionBoth,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Conversations',
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
            child: ListTile(
              onTap: onOpenConversation,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              leading: CircleAvatar(
                backgroundColor: peerProfile.accent.withValues(alpha: 0.18),
                child: Text(
                  peerProfile.label.substring(0, 1),
                  style: TextStyle(
                    color: peerProfile.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(
                peerProfile.label,
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
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: const ListTile(
              leading: Icon(Icons.search_rounded),
              title: Text('Search messages and groups'),
              subtitle: Text(
                'Search is planned in the next implementation pass.',
              ),
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
    required this.activeProfile,
    required this.peerProfile,
    required this.trustRecords,
    required this.activeUserId,
    required this.peerUserId,
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
  final _DemoProfile activeProfile;
  final _DemoProfile peerProfile;
  final List<LocalTrustRecord> trustRecords;
  final String? activeUserId;
  final String? peerUserId;
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
        title: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 14,
              backgroundColor: peerProfile.accent.withValues(alpha: 0.18),
              child: Text(
                peerProfile.label.substring(0, 1),
                style: TextStyle(
                  color: peerProfile.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(peerProfile.label),
          ],
        ),
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
                  activeProfile: activeProfile,
                  peerProfile: peerProfile,
                  trustRecords: trustRecords,
                  activeUserId: activeUserId,
                  peerUserId: peerUserId,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _MessagesPanel(
                    dark: dark,
                    messages: messages,
                    activeUserId: activeUserId,
                    peerLabel: peerProfile.label,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: _ComposerBar(
                  controller: composerController,
                  dark: dark,
                  enabled: firebaseReady && !busy && peerUserId != null,
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
    required this.activeProfile,
    required this.peerProfile,
    required this.forumsService,
    required this.activeUserId,
    required this.composerController,
    required this.busy,
    required this.onCreatePost,
  });

  final bool dark;
  final _DemoProfile activeProfile;
  final _DemoProfile peerProfile;
  final ForumsService forumsService;
  final String? activeUserId;
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
            'Contacts',
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
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: peerProfile.accent.withValues(alpha: 0.18),
                child: Text(
                  peerProfile.label.substring(0, 1),
                  style: TextStyle(
                    color: peerProfile.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(peerProfile.label),
              subtitle: const Text(
                'Demo contact ready for secure direct messaging.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: activeProfile.accent.withValues(alpha: 0.18),
                child: Text(
                  activeProfile.label.substring(0, 1),
                  style: TextStyle(
                    color: activeProfile.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: const Text('You'),
              subtitle: Text('Signed in as ${activeProfile.label}'),
            ),
          ),
          const SizedBox(height: 16),
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
                      enabled: activeUserId != null && !busy,
                      decoration: const InputDecoration(
                        hintText: 'Post to forum',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: activeUserId != null && !busy
                        ? onCreatePost
                        : null,
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
                    .take(8)
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
    required this.activeProfile,
    required this.appGroupsService,
    required this.activeUserId,
    required this.groupNameController,
    required this.busy,
    required this.onCreateGroup,
  });

  final bool dark;
  final _DemoProfile activeProfile;
  final AppGroupsService appGroupsService;
  final String? activeUserId;
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
                      enabled: activeUserId != null && !busy,
                      decoration: const InputDecoration(
                        hintText: 'New group name',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: activeUserId != null && !busy
                        ? onCreateGroup
                        : null,
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
                return Card(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.groups_rounded),
                    title: const Text('No groups yet'),
                    subtitle: Text(
                      'Create the first group for ${activeProfile.label}.',
                    ),
                  ),
                );
              }

              return Column(
                children: groups
                    .take(10)
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
    required this.activeProfile,
    required this.status,
    required this.warning,
    required this.busy,
    required this.localOptions,
    required this.linkedAccount,
    required this.onRegister,
    required this.onSync,
    required this.onProvisionBoth,
    required this.onGoogleSignIn,
    required this.onScanQr,
    required this.onToggleAutoSync,
    required this.onToggleMultiDeviceHints,
    required this.onSetPreferredCamera,
    required this.onSelectProfile,
  });

  final bool dark;
  final _DemoProfile activeProfile;
  final String status;
  final String? warning;
  final bool busy;
  final LocalOptions localOptions;
  final AccountQrPayload? linkedAccount;
  final VoidCallback? onRegister;
  final VoidCallback? onSync;
  final VoidCallback? onProvisionBoth;
  final VoidCallback? onGoogleSignIn;
  final VoidCallback? onScanQr;
  final ValueChanged<bool> onToggleAutoSync;
  final ValueChanged<bool> onToggleMultiDeviceHints;
  final ValueChanged<String> onSetPreferredCamera;
  final ValueChanged<_DemoProfile> onSelectProfile;

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
                  const Text(
                    'Active profile',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<_DemoProfile>(
                    showSelectedIcon: false,
                    segments: _profiles
                        .map(
                          (profile) => ButtonSegment<_DemoProfile>(
                            value: profile,
                            label: Text(profile.label),
                          ),
                        )
                        .toList(growable: false),
                    selected: <_DemoProfile>{activeProfile},
                    onSelectionChanged: (selection) =>
                        onSelectProfile(selection.first),
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
                label: 'Register',
                icon: Icons.key_rounded,
                onPressed: onRegister,
              ),
              _ActionButton(
                label: 'Sync',
                icon: Icons.sync_rounded,
                onPressed: onSync,
              ),
              _ActionButton(
                label: 'Provision Both',
                icon: Icons.devices_rounded,
                onPressed: onProvisionBoth,
              ),
              _ActionButton(
                label: 'Google Sign-In',
                icon: Icons.login_rounded,
                onPressed: onGoogleSignIn,
              ),
              _ActionButton(
                label: 'Scan Account QR',
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
                  title: const Text('Auto-sync on profile switch'),
                  value: localOptions.autoSyncEnabled,
                  onChanged: busy ? null : onToggleAutoSync,
                ),
                SwitchListTile.adaptive(
                  title: const Text('Show multi-device hints'),
                  subtitle: const Text(
                    'Surfaces account/device metadata in status updates.',
                  ),
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

class _BootstrapLoadingPage extends StatelessWidget {
  const _BootstrapLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}
