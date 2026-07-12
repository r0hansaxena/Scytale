import 'package:flutter_test/flutter_test.dart';

import 'package:scytale/models/models.dart';

void main() {
  test('ChatMessage JSON round-trip', () {
    const msg = ChatMessage(
      id: 'abc',
      from: '@alice',
      to: '@bob',
      text: 'hello',
      ts: 1234567890,
      replyTo: 'xyz',
      edited: true,
    );
    final decoded = ChatMessage.fromJson(msg.toJson());
    expect(decoded.id, msg.id);
    expect(decoded.from, msg.from);
    expect(decoded.to, msg.to);
    expect(decoded.text, msg.text);
    expect(decoded.ts, msg.ts);
    expect(decoded.replyTo, msg.replyTo);
    expect(decoded.edited, isTrue);
    expect(decoded.deleted, isFalse);
  });

  test('Reaction emojiId is deterministic and key-safe', () {
    expect(Reaction.emojiId('👍'), Reaction.emojiId('👍'));
    expect(Reaction.emojiId('👍'), isNot(contains('.')));
    expect(Reaction.emojiId('❤️'), isNot(contains('@')));
  });
}
