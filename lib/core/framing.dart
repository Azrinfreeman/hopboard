import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// Length-prefixed UTF-8 JSON. Rejects a frame before allocating its body.
class FrameDecoder {
  final _header = Uint8List(4);
  int _headerOffset = 0;
  Uint8List? _body;
  int _bodyOffset = 0;

  List<Map<String, dynamic>> add(List<int> chunk) {
    final result = <Map<String, dynamic>>[];
    var offset = 0;
    while (offset < chunk.length) {
      if (_body == null) {
        while (_headerOffset < 4 && offset < chunk.length) {
          _header[_headerOffset++] = chunk[offset++];
        }
        if (_headerOffset < 4) break;
        final length = ByteData.sublistView(_header).getUint32(0);
        if (length < 2 || length > maxFrameBytes) {
          throw const FormatException('Invalid frame length.');
        }
        _body = Uint8List(length);
      }
      final body = _body!;
      final count = (chunk.length - offset).clamp(0, body.length - _bodyOffset);
      body.setRange(_bodyOffset, _bodyOffset + count, chunk, offset);
      _bodyOffset += count;
      offset += count;
      if (_bodyOffset == body.length) {
        final value = jsonDecode(utf8.decode(body));
        if (value is! Map<String, dynamic> ||
            value['v'] != protocolVersion ||
            value['type'] is! String) {
          throw const FormatException('Unsupported protocol message.');
        }
        result.add(value);
        if (result.length > 32) {
          throw const FormatException('Too many messages in one chunk.');
        }
        _body = null;
        _headerOffset = _bodyOffset = 0;
      }
    }
    return result;
  }

  bool get incomplete => _headerOffset != 0 || _body != null;
}

Uint8List encodeFrame(Map<String, dynamic> message) {
  final body = utf8.encode(jsonEncode({'v': protocolVersion, ...message}));
  if (body.length > maxFrameBytes) {
    throw const FormatException('Frame too large.');
  }
  final bytes = Uint8List(body.length + 4);
  ByteData.sublistView(bytes).setUint32(0, body.length);
  bytes.setRange(4, bytes.length, body);
  return bytes;
}

class FramedConnection {
  FramedConnection(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _subscription = socket.listen(
      (chunk) {
        try {
          // Do not queue unbounded decoded messages from a flooding peer.
          for (final message in _decoder.add(chunk)) {
            if (++_queuedMessages > 32) {
              throw const FormatException('Message flood.');
            }
            _messages.add(message);
          }
        } catch (_) {
          close();
        }
      },
      onError: (Object _) => close(),
      onDone: close,
    );
  }

  final SecureSocket socket;
  final _decoder = FrameDecoder();
  final _messages = StreamController<Map<String, dynamic>>();
  late final StreamSubscription<Uint8List> _subscription;
  Future<void> _writes = Future.value();
  int _queuedBytes = 0;
  int _queuedMessages = 0;
  bool closed = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream.map((message) {
    _queuedMessages--;
    return message;
  });

  Future<void> send(Map<String, dynamic> message) {
    if (closed) return Future.error(SessionException('Connection closed.'));
    final bytes = encodeFrame(message);
    if (_queuedBytes + bytes.length > 1024 * 1024) {
      close();
      return Future.error(SessionException('Receiver is too slow.'));
    }
    _queuedBytes += bytes.length;
    final write = _writes
        .then((_) async {
          if (closed) throw SessionException('Connection closed.');
          socket.add(bytes);
          await socket.flush().timeout(const Duration(seconds: 5));
        })
        .whenComplete(() => _queuedBytes -= bytes.length);
    _writes = write.catchError((Object _) {
      close();
    });
    return write;
  }

  void post(Map<String, dynamic> message) {
    unawaited(
      send(message).catchError((Object _) {
        close();
      }),
    );
  }

  void close() {
    if (closed) return;
    closed = true;
    socket.destroy();
    unawaited(_subscription.cancel());
    unawaited(_messages.close());
  }
}
