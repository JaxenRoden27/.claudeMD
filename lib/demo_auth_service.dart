import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class DemoAuthProfile {
  const DemoAuthProfile({
    required this.alias,
    required this.label,
    required this.peerAlias,
    required this.email,
    required this.password,
  });

  final String alias;
  final String label;
  final String peerAlias;
  final String email;
  final String password;
}

class DemoAuthSession {
  const DemoAuthSession({
    required this.userId,
    required this.peerUserId,
  });

  final String userId;
  final String? peerUserId;
}

class DemoAuthService {
  DemoAuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Future<UserCredential> signInWithGoogle() async {
    final account = await GoogleSignIn().signIn();
    if (account == null) {
      throw StateError('Google sign-in was cancelled.');
    }

    final googleAuth = await account.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    return _auth.signInWithCredential(credential);
  }

  Future<DemoAuthSession> signInAndResolvePeer(DemoAuthProfile profile) async {
    final credential = await _signInOrCreate(profile);
    final userId = credential.user!.uid;

    await _firestore.collection('demo_aliases').doc(profile.alias).set(
      <String, dynamic>{
        'alias': profile.alias,
        'userId': userId,
        'label': profile.label,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    final peerSnap =
        await _firestore.collection('demo_aliases').doc(profile.peerAlias).get();
    final peerUserId = peerSnap.data()?['userId'] as String?;

    return DemoAuthSession(userId: userId, peerUserId: peerUserId);
  }

  Future<UserCredential> _signInOrCreate(DemoAuthProfile profile) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: profile.email,
        password: profile.password,
      );
    } on FirebaseAuthException catch (error) {
      if (error.code != 'user-not-found' && error.code != 'invalid-credential') {
        rethrow;
      }

      try {
        return await _auth.createUserWithEmailAndPassword(
          email: profile.email,
          password: profile.password,
        );
      } on FirebaseAuthException catch (createError) {
        if (createError.code != 'email-already-in-use') {
          rethrow;
        }

        return _auth.signInWithEmailAndPassword(
          email: profile.email,
          password: profile.password,
        );
      }
    }
  }
}
