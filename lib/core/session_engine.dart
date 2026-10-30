import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'protocol.dart';
import 'content.dart';

class _Accepted {
  _Accepted(this.hash, this.ack, this.age, this.lifetime);
  final String hash;
  final Map<String, dynamic> ack;
  final Duration age;
  final Duration lifetime;
}

/// Authoritative ordering, bounded deduplication, and optimistic conflict checks.
class SessionEngine {
  SessionEngine({String? epoch, Duration Function()? now})
    : epoch = epoch ?? randomSecret(16),
      _clock = Stopwatch()..start() {
    _now = now ?? (() => _clock.elapsed);
  }
  final String epoch;
  final Stopwatch _clock;
  late final Duration Function() _now;
  int sequence = 0;
  ClipItem? item;
  void Function()? onChange;
  final _accepted = <String, LinkedHashMap<String, _Accepted>>{};
  final _rate = <String, Queue<Duration>>{};

  Map<String, dynamic> snapshot({bool content = true}) => {
    'type': 'state',
    'epoch': epoch,
    'seq': sequence,
    'item': item?.expired == false && (content || item!.payload.isText)
        ? item!.toJson()
        : null,
  };

  Map<String, dynamic> publish(
    String deviceId,
    String deviceName,
    Map<String, dynamic> message,
  ) {
    final requestId = field(message, 'requestId', max: 64);
    final payload = ClipPayload.fromJson(message);
    final hash = sha256
        .convert(utf8.encode(jsonEncode(payload.toJson())))
        .toString();
    final cache = _accepted.putIfAbsent(deviceId, LinkedHashMap.new);
    cache.removeWhere((_, value) => _now() - value.age > value.lifetime);
    final previous = cache[requestId];
    if (previous != null) {
      if (previous.hash != hash) {
        throw SessionException(
          'Request ID reused with different content.',
          'request',
        );
      }
      return previous.ack;
    }
    if (message['epoch'] != epoch || message['baseSeq'] != sequence) {
      throw SessionException(
        'Another clipboard changed. Choose which text to use.',
        'conflict',
      );
    }
    final attempts = _rate.putIfAbsent(deviceId, Queue.new);
    attempts.removeWhere((age) => _now() - age >= const Duration(seconds: 1));
    if (attempts.length >= 5) {
      throw SessionException(
        'Clipboard changes are arriving too quickly.',
        'rate',
      );
    }
    attempts.add(_now());
    item = ClipItem(
      id: randomSecret(16),
      sequence: ++sequence,
      senderId: deviceId,
      senderName: deviceName,
      payload: payload,
      lifetime: payload.kind == 'files' ? fileLifetime : itemLifetime,
    );
    final ack = <String, dynamic>{
      'type': 'ack',
      'requestId': requestId,
      'itemId': item!.id,
      'seq': sequence,
    };
    cache[requestId] = _Accepted(
      hash,
      ack,
      _now(),
      payload.kind == 'files' ? fileLifetime : itemLifetime,
    );
    while (cache.length > 256) {
      cache.remove(cache.keys.first);
    }
    onChange?.call();
    return ack;
  }

  void clear() {
    item = null;
    sequence++;
    onChange?.call();
  }

  void forget(String deviceId) {
    _accepted.remove(deviceId);
    _rate.remove(deviceId);
  }
}
