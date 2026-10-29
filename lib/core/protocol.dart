import 'dart:convert';
import 'dart:io';
import 'dart:math';

const protocolVersion = 1;
const maxTextBytes = 64 * 1024;
const maxFrameBytes = 512 * 1024;
const itemLifetime = Duration(minutes: 5);
const serviceType = '_localclip._tcp';
const defaultPort = 47321;

bool isLocalAddress(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 10 ||
      bytes[0] == 127 ||
      bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
      bytes[0] == 192 && bytes[1] == 168 ||
      bytes[0] == 169 && bytes[1] == 254;
}

String randomSecret([int bytes = 32]) {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

String field(Map<String, dynamic> data, String key, {int max = 256}) {
  final value = data[key];
  if (value is! String || value.isEmpty || value.length > max) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String validText(Object? value) {
  if (value is! String || value.isEmpty || value.contains('\u0000')) {
    throw const FormatException('Use non-empty text without null characters.');
  }
  if (utf8.encode(value).length > maxTextBytes) {
    throw const FormatException('Text is limited to 64 KiB.');
  }
  return value;
}

class ClipItem {
  ClipItem({
    required this.id,
    required this.sequence,
    required this.senderId,
    required this.senderName,
    required this.text,
    required Duration lifetime,
  }) : _remaining = lifetime,
       _age = Stopwatch()..start();

  final String id;
  final int sequence;
  final String senderId;
  final String senderName;
  final String text;
  final Duration _remaining;
  final Stopwatch _age;
  Duration get remaining => _remaining - _age.elapsed;
  bool get expired => remaining <= Duration.zero;

  Map<String, dynamic> toJson() => {
    'id': id,
    'seq': sequence,
    'senderId': senderId,
    'senderName': senderName,
    'text': text,
    'remainingMs': remaining.inMilliseconds.clamp(
      0,
      itemLifetime.inMilliseconds,
    ),
  };

  factory ClipItem.fromJson(Map<String, dynamic> data) {
    final seq = data['seq'];
    final ms = data['remainingMs'];
    if (seq is! int ||
        seq < 1 ||
        ms is! int ||
        ms < 0 ||
        ms > itemLifetime.inMilliseconds) {
      throw const FormatException('Invalid item lifetime or sequence.');
    }
    return ClipItem(
      id: field(data, 'id'),
      sequence: seq,
      senderId: field(data, 'senderId'),
      senderName: field(data, 'senderName', max: 64),
      text: validText(data['text']),
      lifetime: Duration(milliseconds: ms),
    );
  }
}

class Invitation {
  Invitation({
    required this.hostId,
    required this.address,
    required this.port,
    required this.fingerprint,
    required this.secret,
  });
  final String hostId;
  final String address;
  final int port;
  final String fingerprint;
  final String secret;

  String encode() => jsonEncode({
    'app': 'localclipboard',
    'v': protocolVersion,
    'hostId': hostId,
    'address': address,
    'port': port,
    'fingerprint': fingerprint,
    'invite': secret,
  });

  factory Invitation.parse(String text) {
    if (text.length > 4096) {
      throw const FormatException('Invitation is too large.');
    }
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic> ||
        data['app'] != 'localclipboard' ||
        data['v'] != protocolVersion) {
      throw const FormatException(
        'This is not a supported Hopboard invitation.',
      );
    }
    final port = data['port'];
    final fp = field(data, 'fingerprint');
    if (!isLocalAddress(field(data, 'address'))) {
      throw const FormatException(
        'Use a local IPv4 address from the host device.',
      );
    }
    if (port is! int ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fp)) {
      throw const FormatException('Invalid connection details.');
    }
    return Invitation(
      hostId: field(data, 'hostId'),
      address: field(data, 'address'),
      port: port,
      fingerprint: fp,
      secret: field(data, 'invite'),
    );
  }
}

class SessionException implements Exception {
  SessionException(this.message, [this.code = 'session']);
  final String message;
  final String code;
  @override
  String toString() => message;
}
