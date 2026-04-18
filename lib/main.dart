import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'auth/auth_wrapper.dart';
import 'signal/signal_fcm_coordinator.dart';
import 'models/app_bootstrap_state.dart';
import 'firebase_options.dart';

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
  _MyApp({Future<AppBootstrapState>? bootstrapFuture})
    : _bootstrapFuture = bootstrapFuture ?? _bootstrapApplication();

  final Future<AppBootstrapState> _bootstrapFuture;

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.light(useMaterial3: true);
    final darkBase = ThemeData.dark(useMaterial3: true);

    const balticBlue = Color(0xFF33658A);
    const blazeOrange = Color(0xFFF26419);
    const honeyBronze = Color(0xFFF6AE2D);
    const skyReflection = Color(0xFF86BBD8);
    const bgLight = Color(0xFFF7F9FC);
    const surfaceLight = Color(0xFFFFFFFF);
    const textPrimaryLight = Color(0xFF1F2933);
    const bgDark = Color(0xFF111827);
    const surfaceDark = Color(0xFF1F2937);
    const textPrimaryDark = Color(0xFFF9FAFB);

    return MaterialApp(
      title: 'Cipher Courier',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        colorScheme: const ColorScheme.light(
          primary: balticBlue,
          secondary: blazeOrange,
          tertiary: honeyBronze,
          surface: surfaceLight,
          onSurface: textPrimaryLight,
          onPrimary: Colors.white,
        ),
        scaffoldBackgroundColor: bgLight,
        textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme),
      ),
      darkTheme: darkBase.copyWith(
        colorScheme: const ColorScheme.dark(
          primary: honeyBronze,
          secondary: blazeOrange,
          tertiary: skyReflection,
          surface: surfaceDark,
          onSurface: textPrimaryDark,
          onPrimary: bgDark,
        ),
        scaffoldBackgroundColor: bgDark,
        textTheme: GoogleFonts.spaceGroteskTextTheme(darkBase.textTheme),
      ),
      themeMode: ThemeMode.system,
      home: FutureBuilder<AppBootstrapState>(
        future: _bootstrapFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const BootstrapLoadingPage();
          }

          return AuthWrapper(
            bootstrapState:
                snapshot.data ?? const AppBootstrapState.firebaseUnavailable(),
          );
        },
      ),
    );
  }
}

Future<AppBootstrapState> _bootstrapApplication() async {
  String? warning;
  var firebaseReady = false;
  var messagingReady = false;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;

    try {
      if (kIsWeb) {
        // App Check for web requires a real reCAPTCHA key; skip here unless configured.
      } else {
        await FirebaseAppCheck.instance.activate(
          androidProvider: kDebugMode
              ? AndroidProvider.debug
              : AndroidProvider.playIntegrity,
          appleProvider: kDebugMode
              ? AppleProvider.debug
              : AppleProvider.deviceCheck,
        );
      }
    } catch (error) {
      warning = _appendWarning(
        warning,
        'App Check setup issue: $error',
      );
    }
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
        'Wake-only push handling is unavailable: $error',
      );
    }
  }

  return AppBootstrapState(
    firebaseReady: firebaseReady,
    messagingReady: messagingReady,
    warning: warning,
  );
}

bool get _supportsMessagingOnCurrentPlatform {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

String _appendWarning(String? current, String next) {
  if (current == null || current.isEmpty) return next;
  return '$current\n$next';
}

class BootstrapLoadingPage extends StatelessWidget {
  const BootstrapLoadingPage({super.key});

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
