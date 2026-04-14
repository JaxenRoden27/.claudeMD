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
