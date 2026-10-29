import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/srp/srp6_client.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

import 'protocol.dart';

// SRP-6a uses the library's fixed RFC 5054 group, never peer-supplied groups.
final _group = SRP6StandardGroups.rfc5054_3072;
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
Uint8List _entropy(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
}

SecureRandom _random() => FortunaRandom()..seed(KeyParameter(_entropy(32)));
String _identity(String hostId) => 'localclipboard/code/v1/$hostId';

String normalizePairCode(String text) {
  final code = text.replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^\d{6}$').hasMatch(code)) {
    throw const FormatException('Enter the six-digit code shown on the host.');
  }
  return code;
}

BigInt _number(Map<String, dynamic> message, String key, {int max = 768}) {
  final value = field(message, key, max: max);
  if (!RegExp(r'^[a-f0-9]+$').hasMatch(value)) {
    throw const FormatException('Invalid pairing proof.');
  }
  return BigInt.parse(value, radix: 16);
}

String _binding(
  BigInt key,
  String role,
  String nonce,
  String hostId,
  String fingerprint,
  BigInt a,
  BigInt b,
) {
  final hex = key.toRadixString(16).padLeft(64, '0');
  final keyBytes = List.generate(
    32,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
  return Hmac(sha256, keyBytes)
      .convert(
        _bytes(
          jsonEncode([
            'localclipboard/code-binding/v1',
            role,
            nonce,
            hostId,
            fingerprint,
            a.toRadixString(16),
            b.toRadixString(16),
          ]),
        ),
      )
      .toString();
}

bool _equal(String actual, Object? expected) {
  if (expected is! String || actual.length != expected.length) return false;
  var difference = 0;
  for (var i = 0; i < actual.length; i++) {
    difference |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return difference == 0;
}

SessionException _failed() => SessionException(
  'Code could not be verified. Check the code and create a new one if needed.',
  'code',
);

class PairCodeWindow {
  PairCodeWindow(this.hostId, this.fingerprint)
    : code = Random.secure().nextInt(1000000).toString().padLeft(6, '0'),
      salt = _entropy(32) {
    verifier = SRP6VerifierGenerator(
      group: _group,
      digest: SHA256Digest(),
    ).generateVerifier(salt, _bytes(_identity(hostId)), _bytes(code));
  }
  final String hostId;
  final String fingerprint;
  final String code;
  final Uint8List salt;
  late final BigInt verifier;
  int _attempts = 0;
  final _bySource = <String, int>{};
  bool get exhausted => _attempts >= 5;

  /// [source] identifies the connecting device, e.g. its IP address.
  PairCodeServer start(String nonce, {String source = ''}) {
    _check(source);
    return PairCodeServer._(this, nonce, source);
  }

  void _check(String source) {
    if (exhausted) {
      throw SessionException(
        'Code attempt limit reached. Create a new invitation on the host.',
        'code',
      );
    }
    if ((_bySource[source] ?? 0) >= 3) {
      throw SessionException(
        'Too many code attempts from this device. Create a new code on the host.',
        'code',
      );
    }
  }

  // Only a submitted proof tests a guess, so only proofs spend attempts.
  // Abandoned handshakes cannot lock the code, and one device cannot spend
  // every attempt by itself.
  void _spend(String source) {
    _check(source);
    _attempts++;
    _bySource[source] = (_bySource[source] ?? 0) + 1;
  }
}

class PairCodeServer {
  PairCodeServer._(this.window, this.nonce, this.source)
    : _srp = SRP6Server(
        group: _group,
        v: window.verifier,
        digest: SHA256Digest(),
        random: _random(),
      ) {
    _srp.generateServerCredentials();
  }
  final PairCodeWindow window;
  final String nonce;
  final String source;
  final SRP6Server _srp;
  int _stage = 0;
  late BigInt _key;

  Map<String, dynamic> challenge() => {
    'type': 'codeChallenge',
    'hostId': window.hostId,
    'fingerprint': window.fingerprint,
    'salt': base64Url.encode(window.salt),
    'b': _srp.B!.toRadixString(16),
  };

  Map<String, dynamic> prove(Map<String, dynamic> message) {
    if (_stage != 0) throw _failed();
    window._spend(source);
    _stage = 1;
    _srp.calculateSecret(_number(message, 'a'));
    if (!_srp.verifyClientEvidenceMessage(_number(message, 'm1', max: 64))) {
      throw _failed();
    }
    final m2 = _srp.calculateServerEvidenceMessage()!;
    _key = _srp.calculateSessionKey()!;
    return {
      'type': 'codeVerified',
      'm2': m2.toRadixString(16),
      'binding': _proof('server'),
    };
  }

  String _proof(String role) => _binding(
    _key,
    role,
    nonce,
    window.hostId,
    window.fingerprint,
    _srp.A!,
    _srp.B!,
  );

  void confirm(Map<String, dynamic> message) {
    if (_stage != 1 || !_equal(_proof('client'), message['binding'])) {
      throw _failed();
    }
    _stage = 2;
  }
}

class PairCodeClient {
  PairCodeClient(String code, this.fingerprint)
    : code = normalizePairCode(code),
      nonce = randomSecret();
  final String code;
  final String fingerprint;
  final String nonce;
  late final String hostId;
  late final SRP6Client _srp;
  int _stage = 0;

  Map<String, dynamic> prove(Map<String, dynamic> message) {
    if (_stage != 0) throw _failed();
    _stage = 1;
    hostId = field(message, 'hostId');
    // Discovery and the initial TLS certificate are untrusted until SRP and
    // both certificate-binding proofs succeed. A relayed SRP exchange fails.
    if (message['fingerprint'] != fingerprint) throw _failed();
    final salt = base64Url.decode(field(message, 'salt', max: 44));
    if (salt.length != 32) throw _failed();
    _srp = SRP6Client(group: _group, digest: SHA256Digest(), random: _random());
    final a = _srp.generateClientCredentials(
      salt,
      _bytes(_identity(hostId)),
      _bytes(code),
    )!;
    _srp.calculateSecret(_number(message, 'b'));
    return {
      'type': 'codeProof',
      'a': a.toRadixString(16),
      'm1': _srp.calculateClientEvidenceMessage()!.toRadixString(16),
    };
  }

  Map<String, dynamic> confirm(Map<String, dynamic> message) {
    if (_stage != 1 ||
        !_srp.verifyServerEvidenceMessage(_number(message, 'm2', max: 64))) {
      throw _failed();
    }
    final key = _srp.calculateSessionKey()!;
    String proof(String role) =>
        _binding(key, role, nonce, hostId, fingerprint, _srp.A!, _srp.B!);
    if (!_equal(proof('server'), message['binding'])) throw _failed();
    _stage = 2;
    return {'type': 'codeConfirm', 'binding': proof('client')};
  }
}
