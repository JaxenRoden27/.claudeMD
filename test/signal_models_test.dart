import 'package:flutter_test/flutter_test.dart';

import 'package:claude_md_final/signal/signal_message_repository.dart';
import 'package:claude_md_final/signal/signal_models.dart';

void main() {
  test('direct conversation ids are stable regardless of ordering', () {
    final first = SignalMessageRepository.directConversationId(
      'demo_alice',
      'demo_bob',
    );
    final second = SignalMessageRepository.directConversationId(
      'demo_bob',
      'demo_alice',
    );

    expect(first, second);
    expect(first, 'direct_demo_alice__demo_bob');
  });

  test('encrypted envelope payload round-trips', () {
    final envelope = SignalEncryptedEnvelope(
      signalMessageType: 3,
      ciphertextBase64: 'ZmFrZV9jaXBoZXJ0ZXh0',
    );

    final restored = SignalEncryptedEnvelope.fromPayload(envelope.toPayload());

    expect(restored.signalMessageType, 3);
    expect(restored.ciphertextBase64, 'ZmFrZV9jaXBoZXJ0ZXh0');
  });
}
