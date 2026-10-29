import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/pair_code.dart';
import 'package:local_clipboard/core/protocol.dart';

void main() {
  test(
    'six-digit codes preserve leading zeroes and allow paste separators',
    () {
      expect(normalizePairCode('001 234'), '001234');
      expect(normalizePairCode('001-234'), '001234');
      for (final value in ['12345', '1234567', 'abcdef', '{"code":123456}']) {
        expect(() => normalizePairCode(value), throwsFormatException);
      }
    },
  );

  test('SRP mutual authentication confirms the exact TLS certificate', () {
    final window = PairCodeWindow('host', 'a' * 64);
    final client = PairCodeClient(window.code, window.fingerprint);
    final server = window.start(client.nonce);
    final proof = client.prove(server.challenge());
    final confirmed = client.confirm(server.prove(proof));
    server.confirm(confirmed);
    expect(client.hostId, 'host');
    expect(() => server.confirm(confirmed), throwsA(isA<SessionException>()));
  });

  test('wrong code cannot produce a valid proof', () {
    final window = PairCodeWindow('host', 'a' * 64);
    final wrong = window.code == '000000' ? '000001' : '000000';
    final client = PairCodeClient(wrong, window.fingerprint);
    final server = window.start(client.nonce);
    final proof = client.prove(server.challenge());
    expect(() => server.prove(proof), throwsA(isA<SessionException>()));
  });

  test(
    'SRP relay across a different TLS certificate fails before confirmation',
    () {
      final window = PairCodeWindow('host', 'a' * 64);
      final client = PairCodeClient(window.code, 'b' * 64);
      final server = window.start(client.nonce);
      // A proxy can relay SRP and rewrite the public challenge fingerprint,
      // but cannot rewrite its authenticated certificate binding.
      final proof = client.prove({
        ...server.challenge(),
        'fingerprint': 'b' * 64,
      });
      final evidence = server.prove(proof);
      expect(() => client.confirm(evidence), throwsA(isA<SessionException>()));
      expect(
        () => server.confirm({'binding': evidence['binding']}),
        throwsA(isA<SessionException>()),
      );
    },
  );

  test('proofs cannot be replayed across sessions or nonces', () {
    final window = PairCodeWindow('host', 'a' * 64);
    final client = PairCodeClient(window.code, window.fingerprint);
    final first = window.start(client.nonce);
    final proof = client.prove(first.challenge());
    final confirmed = client.confirm(first.prove(proof));
    final second = window.start(randomSecret());
    expect(() => second.prove(proof), throwsA(isA<SessionException>()));
    final thirdClient = PairCodeClient(window.code, window.fingerprint);
    final third = window.start(thirdClient.nonce);
    third.prove(thirdClient.prove(third.challenge()));
    expect(() => third.confirm(confirmed), throwsA(isA<SessionException>()));
  });

  test('invalid public values and oversized evidence are rejected', () {
    final window = PairCodeWindow('host', 'a' * 64);
    final server = window.start(randomSecret());
    expect(() => server.prove({'a': '0', 'm1': '0'}), throwsException);
    final client = PairCodeClient(window.code, window.fingerprint);
    expect(
      () => client.prove({...server.challenge(), 'b': 'a' * 769}),
      throwsFormatException,
    );
  });

  test('abandoned handshakes do not spend code attempts', () {
    final window = PairCodeWindow('host', 'a' * 64);
    for (var i = 0; i < 20; i++) {
      window.start(randomSecret(), source: '10.0.0.9');
    }
    expect(window.exhausted, false);
    final client = PairCodeClient(window.code, window.fingerprint);
    final server = window.start(client.nonce, source: '10.0.0.9');
    client.confirm(server.prove(client.prove(server.challenge())));
  });

  test('five proofs exhaust a code and one device may spend only three', () {
    final window = PairCodeWindow('host', 'a' * 64);
    final wrong = window.code == '000000' ? '000001' : '000000';
    void guess(String source) {
      final client = PairCodeClient(wrong, window.fingerprint);
      final server = window.start(client.nonce, source: source);
      expect(
        () => server.prove(client.prove(server.challenge())),
        throwsA(isA<SessionException>()),
      );
    }

    for (var i = 0; i < 3; i++) {
      guess('10.0.0.2');
    }
    expect(
      () => window.start(randomSecret(), source: '10.0.0.2'),
      throwsA(isA<SessionException>()),
    );
    guess('10.0.0.3');
    guess('10.0.0.4');
    expect(window.exhausted, true);
    expect(
      () => window.start(randomSecret(), source: '10.0.0.5'),
      throwsA(isA<SessionException>()),
    );
  });
}
