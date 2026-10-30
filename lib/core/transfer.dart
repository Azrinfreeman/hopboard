import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'content.dart';
import 'framing.dart';
import 'protocol.dart';

const transferIdle = Duration(seconds: 30);

/// A single subscription owns header and raw bytes, including bytes coalesced
/// with the header in one TLS packet. StreamIterator propagates backpressure.
class DataReader {
  DataReader(Stream<Uint8List> stream) : _iterator = StreamIterator(stream);
  final StreamIterator<Uint8List> _iterator;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<Uint8List> _next() async {
    if (_offset < _chunk.length) {
      final result = Uint8List.sublistView(_chunk, _offset);
      _offset = _chunk.length;
      return result;
    }
    if (!await _iterator.moveNext().timeout(transferIdle)) {
      throw const FormatException('Truncated data stream.');
    }
    _chunk = _iterator.current;
    _offset = _chunk.length;
    return _chunk;
  }

  Stream<Uint8List> take(int count) async* {
    while (count > 0) {
      final chunk = await _next();
      final n = chunk.length < count ? chunk.length : count;
      yield Uint8List.sublistView(chunk, 0, n);
      count -= n;
      // _next may have returned a view into an already partially consumed
      // chunk. Keep only its remaining suffix, never reuse its old offset.
      _chunk = chunk;
      _offset = n;
    }
  }

  Future<Uint8List> read(int count) async {
    final result = BytesBuilder(copy: false);
    await for (final bytes in take(count)) {
      result.add(bytes);
    }
    return result.takeBytes();
  }

  Future<Map<String, dynamic>> header() async {
    final length = ByteData.sublistView(await read(4)).getUint32(0);
    if (length < 2 || length > maxFrameBytes) {
      throw const FormatException('Invalid header.');
    }
    final frame = Uint8List(length + 4);
    ByteData.sublistView(frame).setUint32(0, length);
    frame.setRange(4, frame.length, await read(length));
    return FrameDecoder().add(frame).single;
  }

  Stream<Uint8List> rest() async* {
    try {
      if (_offset < _chunk.length) yield Uint8List.sublistView(_chunk, _offset);
      while (await _iterator.moveNext()) {
        yield _iterator.current;
      }
    } finally {
      await cancel();
    }
  }

  Future<void> cancel() => _iterator.cancel();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Trailers authenticate exactly the requested suffix when resuming.
/// A receiver must rehash any retained prefix separately before final use.
Future<void> sendData(
  SecureSocket socket,
  Stream<List<int>> source,
  int size,
) async {
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  var count = 0;
  await for (final chunk in source.timeout(transferIdle)) {
    count += chunk.length;
    if (count > size) {
      throw const FormatException('Source grew after publication.');
    }
    hash.add(chunk);
    socket.add(chunk);
    await socket.flush().timeout(transferIdle);
  }
  if (count != size) {
    throw const FormatException('Source changed after publication.');
  }
  hash.close();
  socket.add(digest.value!.bytes);
  await socket.flush().timeout(transferIdle);
}

Future<Uint8List> receiveData(
  DataReader reader,
  int size,
  Future<void> Function(Uint8List) write,
) async {
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  await for (final chunk in reader.take(size)) {
    hash.add(chunk);
    await write(chunk).timeout(transferIdle);
  }
  hash.close();
  final trailer = await reader.read(32);
  var difference = 0;
  for (var i = 0; i < 32; i++) {
    difference |= trailer[i] ^ digest.value!.bytes[i];
  }
  if (difference != 0) throw const FormatException('Content hash mismatch.');
  return trailer;
}

/// One current item's verified bytes, never more than the cached-tier budget.
class BlobStore {
  String? itemId;
  final _bytes = <int, Uint8List>{};
  int get length => _bytes.values.fold(0, (n, b) => n + b.length);
  Uint8List? get(String id, int entry) => id == itemId ? _bytes[entry] : null;
  void reset(String? id) {
    for (final bytes in _bytes.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _bytes.clear();
    itemId = id;
  }

  void put(String id, int entry, Uint8List bytes) {
    if (id != itemId ||
        _bytes.containsKey(entry) ||
        length + bytes.length > cachedItemBytes) {
      throw SessionException('Cache item changed or is full.', 'expired');
    }
    _bytes[entry] = bytes;
  }
}

typedef ContentSource = Future<Stream<List<int>>> Function(
  String itemId,
  int entry,
  int offset,
);

class _Ticket {
  _Ticket(this.device, this.item, this.entry, this.offset, this.role, this.size)
    : age = Stopwatch()..start();
  final String device, item, role;
  final int entry, offset, size;
  final Stopwatch age;
  String? token;
}

class _Serving {
  _Serving(this.fetch, this.downstream);
  final _Ticket fetch;
  final SecureSocket? downstream;
  SecureSocket? upstream;
  final ready = Completer<DataReader>();
  final done = Completer<void>();

  void cancel() {
    downstream?.destroy();
    upstream?.destroy();
    if (!ready.isCompleted) {
      ready.completeError(SessionException('Transfer cancelled.', 'expired'));
    }
    if (!done.isCompleted) done.complete();
  }
}

/// Credential validation remains with LocalHost. Tickets also require a live
/// authenticated control peer and bind every byte stream to its current item.
class TransferHost {
  TransferHost({
    required this.current,
    required this.online,
    required this.post,
    required this.hostId,
  });
  final ClipItem? Function() current;
  final bool Function(String) online;
  final void Function(String, Map<String, dynamic>) post;
  final String hostId;
  ContentSource? source;
  void Function()? onCacheChange;
  final blobs = BlobStore();
  final _tickets = <String, _Ticket>{};
  final _rates = <String, List<Duration>>{};
  final _clock = Stopwatch()..start();
  final _active = <SecureSocket, _Ticket>{};
  final _serving = <String, _Serving>{};
  final _uploads = <_Ticket>{};
  int _generation = 0;

  /// A host receives through the same relay and hash checks as a remote peer,
  /// without opening an unnecessary connection back to itself.
  Future<void> fetchLocal(
    ClipItem item,
    int entry,
    Future<void> Function(Uint8List) write,
  ) async {
    if (current()?.id != item.id || item.expired) {
      throw SessionException('Item expired.', 'expired');
    }
    final cached = blobs.get(item.id, entry);
    if (cached != null) {
      for (var offset = 0; offset < cached.length; offset += 65536) {
        await write(
          Uint8List.sublistView(
            cached,
            offset,
            (offset + 65536).clamp(0, cached.length),
          ),
        );
      }
      return;
    }
    if (item.senderId == hostId && source != null) {
      final size = item.payload.streams[entry];
      if (size == null) throw const FormatException('Invalid entry.');
      var length = 0;
      await for (final bytes in await source!(item.id, entry, 0)) {
        if (current()?.id != item.id || item.expired) {
          throw SessionException('Item expired.', 'expired');
        }
        length += bytes.length;
        if (length > size) throw const FormatException('File is too long.');
        await write(Uint8List.fromList(bytes));
      }
      if (length != size) throw const FormatException('File is incomplete.');
      return;
    }
    final token = issue(item.senderId, item.id, entry, 0, 'serve');
    final serving = _Serving(
      _Ticket(hostId, item.id, entry, 0, 'fetch', item.payload.streams[entry]!),
      null,
    );
    _serving[token] = serving;
    post(item.senderId, {
      'type': 'serve',
      'itemId': item.id,
      'entry': entry,
      'offset': 0,
      'ticket': token,
      'size': item.payload.streams[entry],
    });
    try {
      await receiveData(
        await serving.ready.future.timeout(transferIdle),
        item.payload.streams[entry]!,
        write,
      );
    } finally {
      _tickets.remove(token);
      _serving.remove(token);
      if (!serving.done.isCompleted) serving.done.complete();
      serving.upstream?.destroy();
    }
  }

  void reset({bool clearCache = true}) {
    _generation++;
    _tickets.clear();
    for (final serving in _serving.values.toList()) {
      serving.cancel();
    }
    _serving.clear();
    _uploads.clear();
    for (final socket in _active.keys.toList()) {
      socket.destroy();
    }
    _active.clear();
    if (clearCache) blobs.reset(current()?.id);
  }

  void forget(String device) {
    for (final entry in _serving.entries.toList()) {
      if (entry.value.fetch.device == device ||
          _tickets[entry.key]?.device == device ||
          _active[entry.value.upstream]?.device == device) {
        entry.value.cancel();
      }
    }
    _tickets.removeWhere((_, t) => t.device == device);
    _rates.remove(device);
    for (final entry in _active.entries.toList()) {
      if (entry.value.device == device) entry.key.destroy();
    }
  }

  String issue(
    String device,
    String itemId,
    int entry,
    int offset,
    String role,
  ) {
    final item = current();
    if (item == null || item.expired || item.id != itemId || !online(device)) {
      throw SessionException('Item expired or device disconnected.', 'expired');
    }
    final size = item.payload.streams[entry];
    if (size == null ||
        offset < 0 ||
        offset > size ||
        !{'fetch', 'upload', 'serve'}.contains(role) ||
        role != 'fetch' &&
            (device != item.senderId || offset != 0 && role == 'upload') ||
        role == 'upload' && !item.payload.cached) {
      throw const FormatException('Invalid transfer request.');
    }
    if (role == 'fetch' &&
        blobs.get(itemId, entry) == null &&
        item.senderId != hostId &&
        !online(item.senderId)) {
      throw SessionException('Sender is offline.', 'senderOffline');
    }
    _tickets.removeWhere((_, t) => t.age.elapsed > const Duration(seconds: 60));
    final rate = _rates.putIfAbsent(device, () => []);
    rate.removeWhere((t) => _clock.elapsed - t > const Duration(seconds: 1));
    if (role != 'serve' && rate.length >= 20 || _tickets.length >= 128) {
      throw SessionException('Transfers are busy.', 'busy');
    }
    if (role != 'serve') rate.add(_clock.elapsed);
    final token = randomSecret(16);
    _tickets[token] = _Ticket(
      device,
      itemId,
      entry,
      offset,
      role,
      size - offset,
    )..token = token;
    return token;
  }

  void cancel(String device, String token) {
    if (_tickets[token]?.device == device) _tickets.remove(token);
    for (final serving in _serving.values.toList()) {
      if (serving.fetch.device == device && serving.fetch.token == token) {
        serving.cancel();
      }
    }
    // Active cancellation closes only sockets belonging to the requester.
    for (final e in _active.entries.toList()) {
      if (e.value.device == device && e.value.token == token) e.key.destroy();
    }
  }

  Future<void> accept(
    SecureSocket socket,
    DataReader reader,
    Map<String, dynamic> header,
  ) async {
    final token = field(header, 'ticket');
    final ticket = _tickets[token];
    final item = current();
    if (ticket == null ||
        ticket.device != header['deviceId'] ||
        ticket.role != header['role'] ||
        ticket.age.elapsed > const Duration(seconds: 60) ||
        item == null ||
        item.expired ||
        item.id != ticket.item ||
        !online(ticket.device)) {
      throw SessionException('Invalid data ticket.', 'unauthorized');
    }
    _tickets.remove(token);
    if (_active.length >= 16 ||
        _active.values.where((t) => t.device == ticket.device).length >= 2 ||
        ticket.role == 'fetch' &&
            _active.values.where((t) => t.role == 'fetch').length >= 8) {
      throw SessionException('Transfers are busy.', 'busy');
    }
    _active[socket] = ticket;
    final generation = _generation;
    try {
      if (ticket.role == 'serve') {
        final serving = _serving[token];
        if (serving == null) {
          throw SessionException('Transfer cancelled.', 'expired');
        }
        serving.upstream = socket;
        serving.ready.complete(reader);
        await serving.done.future;
      } else if (ticket.role == 'upload') {
        if (_uploads.any(
              (t) => t.item == ticket.item && t.entry == ticket.entry,
            ) ||
            blobs.get(ticket.item, ticket.entry) != null) {
          throw SessionException('Upload already started.', 'busy');
        }
        _uploads.add(ticket);
        final bytes = Uint8List(ticket.size);
        var offset = 0;
        try {
          await receiveData(reader, ticket.size, (chunk) async {
            bytes.setRange(offset, offset + chunk.length, chunk);
            offset += chunk.length;
          });
          if (generation != _generation || !online(ticket.device)) {
            throw SessionException('Transfer cancelled.', 'expired');
          }
          blobs.put(ticket.item, ticket.entry, bytes);
          onCacheChange?.call();
          socket.add(encodeFrame({'type': 'stored'}));
          await socket.flush().timeout(transferIdle);
        } catch (_) {
          bytes.fillRange(0, bytes.length, 0);
          rethrow;
        } finally {
          _uploads.remove(ticket);
        }
      } else {
        final cached = blobs.get(ticket.item, ticket.entry);
        if (cached != null) {
          await sendData(
            socket,
            Stream.value(Uint8List.sublistView(cached, ticket.offset)),
            ticket.size,
          );
        } else if (item.senderId == hostId && source != null) {
          await sendData(
            socket,
            await source!(ticket.item, ticket.entry, ticket.offset),
            ticket.size,
          );
        } else {
          if (!online(item.senderId)) {
            throw SessionException('Sender is offline.', 'senderOffline');
          }
          final serveToken = issue(
            item.senderId,
            ticket.item,
            ticket.entry,
            ticket.offset,
            'serve',
          );
          final serving = _Serving(ticket, socket);
          _serving[serveToken] = serving;
          post(item.senderId, {
            'type': 'serve',
            'itemId': ticket.item,
            'entry': ticket.entry,
            'offset': ticket.offset,
            'ticket': serveToken,
            'size': ticket.size,
          });
          try {
            final upstream = await serving.ready.future.timeout(transferIdle);
            // Validate the upstream trailer before forwarding our own. A bad
            // sender cannot leave a receiver with a verified partial file.
            final trailer = await receiveData(upstream, ticket.size, (
              chunk,
            ) async {
              socket.add(chunk);
              await socket.flush().timeout(transferIdle);
            });
            socket.add(trailer);
            await socket.flush().timeout(transferIdle);
          } finally {
            _tickets.remove(serveToken);
            _serving.remove(serveToken);
            if (!serving.done.isCompleted) serving.done.complete();
            serving.upstream?.destroy();
          }
        }
      }
    } finally {
      _active.remove(socket);
    }
  }
}

/// Explicit transport API; clipboard integration opts in only once it can
/// receive rich items. All bulk sockets share the control connection's pin.
class TransferClient {
  TransferClient({
    required this.connect,
    required this.request,
    required this.deviceId,
    required this.credential,
    this.onCancel,
  });
  final Future<SecureSocket> Function() connect;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) request;
  final String deviceId, credential;
  final void Function(String token)? onCancel;
  ContentSource? source;
  final _active = <SecureSocket, String>{};
  bool _stopped = false;
  int _generation = 0;

  Future<SecureSocket> _open(String role, String token, int generation) async {
    if (_stopped || generation != _generation || _active.length >= 2) {
      throw SessionException('Transfers unavailable.', 'busy');
    }
    final socket = await connect();
    if (_stopped || generation != _generation || _active.length >= 2) {
      socket.destroy();
      throw SessionException('Transfer cancelled.', 'busy');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _active[socket] = token;
    socket.add(
      encodeFrame({
        'type': 'data',
        'deviceId': deviceId,
        'credential': credential,
        'role': role,
        'ticket': token,
      }),
    );
    return socket;
  }

  Future<void> serve(Map<String, dynamic> message) async {
    final generation = _generation;
    final source = this.source;
    if (source == null) return;
    final item = field(message, 'itemId');
    final entry = boundedInt(message['entry'], 0, 4999);
    final offset = boundedInt(message['offset'], 0, defaultItemBytes);
    final size = boundedInt(message['size'], 0, defaultItemBytes);
    final socket = await _open('serve', field(message, 'ticket'), generation);
    try {
      await sendData(socket, await source(item, entry, offset), size);
    } finally {
      _active.remove(socket);
      socket.destroy();
    }
  }

  Future<String> ticket(String role, String item, int entry, int offset) async {
    final generation = _generation;
    for (var attempt = 0; ; attempt++) {
      if (_stopped || generation != _generation) {
        throw SessionException('Transfer cancelled.', 'expired');
      }
      try {
        final response = await request({
          'type': role,
          'requestId': randomSecret(16),
          'itemId': item,
          'entry': entry,
          'offset': offset,
        });
        return field(response, 'ticket');
      } on SessionException catch (error) {
        // Small multi-file items may legitimately exceed the ticket rate.
        if (error.code != 'busy' || attempt >= 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> upload(ClipItem item) async {
    final generation = _generation;
    final source = this.source;
    if (!item.payload.cached || source == null || item.senderId != deviceId) {
      throw const FormatException('Item cannot be uploaded.');
    }
    for (final e in item.payload.streams.entries) {
      final token = await ticket('upload', item.id, e.key, 0);
      final socket = await _open('upload', token, generation);
      final reader = DataReader(socket);
      try {
        await sendData(socket, await source(item.id, e.key, 0), e.value);
        if ((await reader.header())['type'] != 'stored') {
          throw const FormatException('Upload not stored.');
        }
      } finally {
        _active.remove(socket);
        socket.destroy();
        await reader.cancel();
      }
    }
  }

  /// The caller writes a private partial file and exposes it only on success.
  /// On failure or cancellation it must discard all bytes written by this call.
  Future<void> fetch(
    ClipItem item,
    int entry,
    Future<void> Function(Uint8List) write, {
    int offset = 0,
  }) async {
    final generation = _generation;
    final size = item.payload.streams[entry];
    if (size == null || offset < 0 || offset > size || item.expired) {
      throw const FormatException('Invalid fetch.');
    }
    final token = await ticket('fetch', item.id, entry, offset);
    final socket = await _open('fetch', token, generation);
    final reader = DataReader(socket);
    try {
      await receiveData(reader, size - offset, write);
    } finally {
      _active.remove(socket);
      socket.destroy();
      await reader.cancel();
    }
  }

  void cancel() {
    _generation++;
    for (final entry in _active.entries.toList()) {
      onCancel?.call(entry.value);
      entry.key.destroy();
    }
    _active.clear();
  }

  void stop() {
    _stopped = true;
    cancel();
  }
}
