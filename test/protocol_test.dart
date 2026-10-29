import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/framing.dart';
import 'package:local_clipboard/core/protocol.dart';
import 'package:local_clipboard/core/session_engine.dart';

void main() {
  test('network destinations are limited to local IPv4 addresses', () {
    for (final address in [
      '10.0.0.1',
      '172.20.10.2',
      '192.168.1.8',
      '127.0.0.1',
      '169.254.1.2',
    ]) {
      expect(isLocalAddress(address), true);
    }
    for (final address in [
      '8.8.8.8',
      'example.com',
      '0.0.0.0',
      '172.32.0.1',
      '::1',
    ]) {
      expect(isLocalAddress(address), false);
    }
  });
  test('framing survives arbitrary fragmentation and multiple messages', () {
    final decoder = FrameDecoder();
    final bytes = [
      ...encodeFrame({'type': 'publish', 'text': 'Hello 👋\nمرحبا'}),
      ...encodeFrame({'type': 'ping'}),
    ];
    final messages = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      messages.addAll(decoder.add([byte]));
    }
    expect(messages.map((m) => m['type']), ['publish', 'ping']);
    expect(messages.first['text'], 'Hello 👋\nمرحبا');
    expect(decoder.incomplete, false);
  });

  test(
    'oversized frames and malformed protocol rejected before body allocation',
    () {
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, maxFrameBytes + 1);
      expect(() => FrameDecoder().add(header), throwsFormatException);
      final invalid = utf8.encode('{"v":999,"type":"ping"}');
      final bytes = Uint8List(invalid.length + 4)
        ..setRange(4, invalid.length + 4, invalid);
      ByteData.sublistView(bytes).setUint32(0, invalid.length);
      expect(() => FrameDecoder().add(bytes), throwsFormatException);
    },
  );

  test('byte limits preserve Unicode and reject nulls / empty text', () {
    expect(validText('é' * (maxTextBytes ~/ 2)).length, maxTextBytes ~/ 2);
    expect(
      () => validText('é' * (maxTextBytes ~/ 2 + 1)),
      throwsFormatException,
    );
    expect(() => validText(''), throwsFormatException);
    expect(() => validText('hello\u0000world'), throwsFormatException);
    final escaped = '\u0001' * maxTextBytes;
    expect(
      encodeFrame({'type': 'publish', 'text': validText(escaped)}).length,
      lessThan(maxFrameBytes),
    );
  });

  test(
    'deduplication precedes conflict validation and never rebroadcasts a retry',
    () {
      final engine = SessionEngine(epoch: 'test');
      var changes = 0;
      engine.onChange = () => changes++;
      final message = {
        'requestId': 'first',
        'text': 'hello',
        'epoch': 'test',
        'baseSeq': 0,
      };
      final ack = engine.publish('a', 'Alice', message);
      expect(engine.publish('a', 'Alice', message), ack);
      expect(engine.sequence, 1);
      expect(changes, 1);
      expect(
        () => engine.publish('a', 'Alice', {...message, 'text': 'different'}),
        throwsA(
          isA<SessionException>().having((e) => e.code, 'code', 'request'),
        ),
      );
    },
  );

  test('concurrent stale publication cannot overwrite accepted text', () {
    final engine = SessionEngine(epoch: 'test');
    engine.publish('a', 'Alice', {
      'requestId': 'a1',
      'text': 'first',
      'epoch': 'test',
      'baseSeq': 0,
    });
    expect(
      () => engine.publish('b', 'Bob', {
        'requestId': 'b1',
        'text': 'second',
        'epoch': 'test',
        'baseSeq': 0,
      }),
      throwsA(
        isA<SessionException>().having((e) => e.code, 'code', 'conflict'),
      ),
    );
    expect(engine.item!.text, 'first');
    engine.clear();
    expect(engine.snapshot()['item'], null);
    expect(engine.sequence, 2);
  });

  test('10,000 sequential accepted changes retain latest state and reject stale epochs', () {
    var now = Duration.zero;
    final engine = SessionEngine(epoch: 'run', now: () => now);
    for (var index = 0; index < 10000; index++) {
      now += const Duration(milliseconds: 250);
      engine.publish('a', 'Alice', {
        'requestId': 'request-$index',
        'text': '$index',
        'epoch': 'run',
        'baseSeq': index,
      });
    }
    expect(engine.sequence, 10000);
    expect(engine.item!.text, '9999');
    expect(
      () => engine.publish('a', 'Alice', {
        'requestId': 'old',
        'text': 'stale',
        'epoch': 'old-run',
        'baseSeq': 10000,
      }),
      throwsA(isA<SessionException>()),
    );
  });

  test('rate limiting bounds a flooding authenticated sender', () {
    final engine = SessionEngine(epoch: 'test', now: () => Duration.zero);
    for (var i = 0; i < 5; i++) {
      engine.publish('a', 'Alice', {
        'requestId': '$i',
        'text': '$i',
        'epoch': 'test',
        'baseSeq': i,
      });
    }
    expect(
      () => engine.publish('a', 'Alice', {
        'requestId': 'flood',
        'text': 'six',
        'epoch': 'test',
        'baseSeq': 5,
      }),
      throwsA(isA<SessionException>().having((e) => e.code, 'code', 'rate')),
    );
  });

  test(
    'invitation includes exact host identity and rejects unknown apps/versions',
    () {
      final invite = Invitation(
        hostId: 'id',
        address: '192.168.1.2',
        port: 47321,
        fingerprint: 'a' * 64,
        secret: 'random-invite',
      );
      final parsed = Invitation.parse(invite.encode());
      expect(parsed.fingerprint, invite.fingerprint);
      expect(parsed.secret, invite.secret);
      expect(
        () => Invitation.parse('{"app":"other","v":1}'),
        throwsFormatException,
      );
    },
  );
}
