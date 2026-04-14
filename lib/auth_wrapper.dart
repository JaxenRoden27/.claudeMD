import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'login_page.dart';
import 'signal_chat_page.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key, required this.bootstrapState});

  final AppBootstrapState bootstrapState;

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();

    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final user = snapshot.data;
        if (user != null) {
          return SignalChatPage(
            bootstrapState: bootstrapState,
            user: user,
          );
        }

        return const LoginPage();
      },
    );
  }
}
