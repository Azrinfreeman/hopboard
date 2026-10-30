import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/client.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/core/framing.dart';
import 'package:local_clipboard/core/host.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/core/protocol.dart';
import 'package:local_clipboard/core/session_engine.dart';
import 'package:local_clipboard/core/transfer.dart';

Map<String, dynamic> manifest(int size, {String path = 'payload.zip'}) => {
  'kind': 'files',
  'totalBytes': size,
  'fileCount': 1,
  'roots': [path],
  'entries': [
    {'i': 0, 'path': path, 'size': size},
  ],
};

Future<Map<String, dynamic>> next(SessionClient client, String type) => client
    .events
    .stream
    .firstWhere((m) => m['type'] == type)
    .timeout(const Duration(seconds: 10));

void main() {
  test(
    'manifest rejects traversal, aliases, unsafe names and inconsistent totals',
    () {
      for (final path in [
        '../a',
        '/a',
        'C:/a',
        r'a\b',
        'a:b',
        'CON.txt',
        'lpt1',
        'a.',
        'a ',
        'a//b',
        'a/./b',
        'a\u0000',
        'e\u0301.txt',
        'a?b',
      ]) {
        expect(
          () => ClipPayload.fromJson(manifest(1, path: path)),
          throwsFormatException,
          reason: path,
        );
      }
      expect(
        () => ClipPayload.fromJson({...manifest(1), 'totalBytes': 2}),
        throwsFormatException,
      );
      final collision = manifest(1);
      collision['entries'] = [
        {'i': 0, 'path': 'a', 'size': 0},
        {'i': 1, 'path': 'A', 'size': 1},
      ];
      expect(() => ClipPayload.fromJson(collision), throwsFormatException);
      expect(
        () => ClipPayload.fromJson(manifest(defaultItemBytes + 1)),
        throwsFormatException,
      );
      expect(
        () => ClipPayload.fromJson({
          'kind': 'image',
          'mime': 'image/png',
          'size': 2,
          'width': 16384,
          'height': 16384,
        }),
        throwsFormatException,
      );
    },
  );

  test('content round trips and leaves text wire shape unchanged', () {
    for (final payload in [
      {'text': 'hello'},
      manifest(42),
      {
        'kind': 'image',
        'mime': 'image/png',
        'size': 2,
        'width': 1,
        'height': 1,
      },
      {
        'kind': 'mixed',
        'text': 'cells',
        'image': {'mime': 'image/png', 'size': 2, 'width': 1, 'height': 1},
      },
    ]) {
      final item = ClipItem(
        id: 'item',
        sequence: 1,
        senderId: 'a',
        senderName: 'A',
        payload: ClipPayload.fromJson(payload),
        lifetime: itemLifetime,
      );
      final json = item.toJson();
      expect(ClipItem.fromJson(json).payload.toJson(), item.payload.toJson());
      if (item.kind == 'text') expect(json.containsKey('kind'), false);
    }
  });

  test('file publication retries stay deduplicated for the file lifetime', () {
    var time = Duration.zero;
    final engine = SessionEngine(now: () => time);
    final message = {
      'requestId': 'retry',
      'epoch': engine.epoch,
      'baseSeq': 0,
      ...manifest(1),
    };
    final ack = engine.publish('sender', 'Sender', message);
    time = const Duration(minutes: 6);
    expect(engine.publish('sender', 'Sender', message), ack);
    expect(engine.sequence, 1);
  });

  test(
    'header parsing retains coalesced raw bytes and fragmented frames',
    () async {
      final frame = encodeFrame({'type': 'data'});
      for (final chunks in [
        [
          Uint8List.fromList([...frame, 7, 8]),
        ],
        [
          ...frame.map((b) => Uint8List.fromList([b])),
          Uint8List.fromList([7, 8]),
        ],
      ]) {
        final reader = DataReader(Stream.fromIterable(chunks));
        expect((await reader.header())['type'], 'data');
        expect(await reader.read(2), [7, 8]);
        await reader.cancel();
      }
    },
  );

  late Identity identity;
  setUpAll(() {
    identity = Identity.generate();
  });

  Future<(LocalHost, SessionClient, SessionClient, SessionClient)>
  session() async {
    final host = LocalHost(identity, TrustStore(MemoryVault()), 'Host');
    await host.start('127.0.0.1', 0);
    addTearDown(host.stop);
    final approval = host.pairing.stream.listen((r) => r.decide(true));
    addTearDown(approval.cancel);
    final clients = <SessionClient>[];
    for (var i = 0; i < 3; i++) {
      final peer = Identity(
        'peer-$i',
        identity.certificate,
        identity.privateKey,
      );
      final saved = await SessionClient.pair(peer, 'Peer $i', host.invite());
      final client = SessionClient(peer, saved, content: i < 2);
      clients.add(client);
      addTearDown(client.stop);
      await client.connect();
    }
    return (host, clients[0], clients[1], clients[2]);
  }

  Future<ClipItem> publish(
    LocalHost host,
    SessionClient sender,
    int size,
  ) async {
    final ack = next(sender, 'ack');
    await sender.send({
      'type': 'publish',
      'requestId': randomSecret(16),
      'epoch': host.engine.epoch,
      'baseSeq': host.engine.sequence,
      ...manifest(size),
    });
    await ack;
    return ClipItem.fromJson(
      host.engine.snapshot()['item'] as Map<String, dynamic>,
    );
  }

  test(
    'cached upload survives sender disconnect; legacy stays connected for text',
    () async {
      final (host, sender, receiver, legacy) = await session();
      final legacyState = next(legacy, 'state');
      final item = await publish(host, sender, 1024 * 1024);
      expect((await legacyState)['item'], null);
      final bytes = Uint8List(item.payload.totalBytes)
        ..fillRange(0, item.payload.totalBytes, 73);
      sender.transfers.source = (_, _, offset) async =>
          Stream.value(Uint8List.sublistView(bytes, offset));
      await sender.transfers.upload(item);
      expect(host.transfers.blobs.length, bytes.length);
      sender.stop();
      final receiverGone = next(receiver, 'disconnected');
      final legacyGone = next(legacy, 'disconnected');
      await host.rebind('127.0.0.1');
      await Future.wait([receiverGone, legacyGone]);
      await receiver.connect();
      await legacy.connect();
      expect(host.transfers.blobs.length, bytes.length);
      var received = 0;
      await receiver.transfers.fetch(item, 0, (chunk) async {
        expect(chunk.every((b) => b == 73), true);
        received += chunk.length;
      });
      expect(received, bytes.length);
      final state = next(legacy, 'state');
      host.publish({
        'requestId': 'text',
        'epoch': host.engine.epoch,
        'baseSeq': host.engine.sequence,
        'text': 'still connected',
      });
      expect(((await state)['item'] as Map)['text'], 'still connected');
      expect(host.transfers.blobs.length, 0);
    },
  );

  test(
    'relay 1 GiB with bounded memory, slow sink, ping and resume',
    () async {
      final (host, sender, receiver, _) = await session();
      const size = 1024 * 1024 * 1024;
      final item = await publish(host, sender, size);
      final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 19);
      var generated = 0;
      var received = 0;
      var maxAhead = 0;
      sender.transfers.source = (_, _, offset) async => (() async* {
        for (var pos = offset; pos < size; pos += chunk.length) {
          final n = (size - pos).clamp(0, chunk.length);
          generated += n;
          if (generated - received > maxAhead) maxAhead = generated - received;
          yield Uint8List.sublistView(chunk, 0, n);
        }
      })();
      // Warm up TLS/hash buffers before measuring a second full stream.
      await receiver.transfers.fetch(
        item,
        0,
        (c) async {},
        offset: size - chunk.length,
      );
      generated = 0;
      final baseline = ProcessInfo.currentRss;
      var peak = baseline;
      var pinged = false;
      final sample = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
      });
      try {
        await receiver.transfers.fetch(item, 0, (c) async {
          received += c.length;
          if (!pinged && received > 1024 * 1024) {
            pinged = true;
            final pong = next(receiver, 'pong');
            await receiver.send({'type': 'ping'});
            await pong;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        });
      } finally {
        sample.cancel();
      }
      expect(received, size);
      expect(pinged, true);
      expect(host.transfers.blobs.length, 0);
      expect(maxAhead, lessThan(32 * 1024 * 1024));
      // This process includes sender, host, receiver and the Flutter test VM.
      expect(peak - baseline, lessThan(128 * 1024 * 1024));
    },
    timeout: const Timeout(Duration(minutes: 8)),
    tags: ['large'],
  );

  test('hash mismatch and truncated streams are rejected', () async {
    for (final bytes in [
      Uint8List.fromList([1, 2, ...List.filled(32, 0)]),
      Uint8List.fromList([1]),
    ]) {
      final reader = DataReader(Stream.value(bytes));
      await expectLater(
        receiveData(reader, 2, (_) async {}),
        throwsFormatException,
      );
      await reader.cancel();
    }
  });

  for (final action in ['cancel', 'clear', 'revoke']) {
    test('$action aborts an active relay and releases the sender', () async {
      final (host, sender, receiver, _) = await session();
      final item = await publish(host, sender, cachedItemBytes + 1);
      final blocked = Completer<void>();
      final released = Completer<void>();
      final pause = Completer<void>();
      addTearDown(() {
        if (!pause.isCompleted) pause.complete();
      });
      sender.transfers.source = (_, _, _) async => (() async* {
        try {
          yield Uint8List(64 * 1024);
          blocked.complete();
          await pause.future;
          yield Uint8List(1);
        } finally {
          released.complete();
        }
      })();
      final started = Completer<void>();
      final fetch = receiver.transfers.fetch(item, 0, (_) async {
        if (!started.isCompleted) started.complete();
      });
      final failed = expectLater(fetch, throwsA(anything));
      await started.future.timeout(const Duration(seconds: 5));
      await blocked.future;
      switch (action) {
        case 'cancel':
          receiver.transfers.cancel();
        case 'clear':
          host.engine.clear();
        case 'revoke':
          await host.revoke(receiver.identity.id);
      }
      await failed.timeout(const Duration(seconds: 5));
      // Release a deliberately stalled source; no more than its first chunk
      // can reach the cancelled receiver, and a new item can transfer normally.
      pause.complete();
      await released.future.timeout(const Duration(seconds: 5));
      final replacement = await publish(host, sender, 1);
      sender.transfers.source = (_, _, _) async => Stream.value([7]);
      await sender.transfers.upload(replacement);
      expect(host.transfers.blobs.get(replacement.id, 0), [7]);
    });
  }

  test('cancel while awaiting a ticket never opens a data socket', () async {
    final ticket = Completer<Map<String, dynamic>>();
    var connections = 0;
    final client = TransferClient(
      connect: () async {
        connections++;
        throw StateError('A cancelled operation must not connect.');
      },
      request: (_) => ticket.future,
      deviceId: 'receiver',
      credential: 'credential',
    );
    final item = ClipItem(
      id: 'item',
      sequence: 1,
      senderId: 'sender',
      senderName: 'Sender',
      payload: ClipPayload.fromJson(manifest(1)),
      lifetime: itemLifetime,
    );
    final failed = expectLater(
      client.fetch(item, 0, (_) async {}),
      throwsA(isA<SessionException>()),
    );
    client.cancel();
    ticket.complete({'ticket': 'stale'});
    await failed;
    expect(connections, 0);
  });

  test(
    'many cached files respect ticket throttling without losing the upload',
    () async {
      final (host, sender, receiver, _) = await session();
      const count = 24;
      final ack = next(sender, 'ack');
      await sender.send({
        'type': 'publish',
        'requestId': 'many-files',
        'epoch': host.engine.epoch,
        'baseSeq': host.engine.sequence,
        'kind': 'files',
        'totalBytes': count,
        'fileCount': count,
        'roots': [for (var i = 0; i < count; i++) '$i.txt'],
        'entries': [
          for (var i = 0; i < count; i++) {'i': i, 'path': '$i.txt', 'size': 1},
        ],
      });
      await ack;
      final item = host.engine.item!;
      sender.transfers.source = (_, entry, _) async => Stream.value([entry]);
      await sender.transfers.upload(item);
      expect(host.transfers.blobs.length, count);
      for (var entry = 0; entry < count; entry++) {
        final bytes = <int>[];
        await receiver.transfers.fetch(
          item,
          entry,
          (chunk) async => bytes.addAll(chunk),
        );
        expect(bytes, [entry]);
      }
    },
  );

  test(
    'uncached items report senderOffline through the control connection',
    () async {
      final (host, sender, receiver, _) = await session();
      final item = await publish(host, sender, cachedItemBytes + 1);
      await host.revoke(sender.identity.id);
      await expectLater(
        receiver.transfers.fetch(item, 0, (_) async {}),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            'senderOffline',
          ),
        ),
      );
      final pong = next(receiver, 'pong');
      await receiver.send({'type': 'ping'});
      await pong;
    },
  );

  test(
    'tickets reject forgery, wrong peer, reuse and superseded items',
    () async {
      final (host, sender, receiver, _) = await session();
      final item = await publish(host, sender, 1);
      sender.transfers.source = (_, _, _) async => Stream.value([9]);
      await sender.transfers.upload(item);
      final token = await receiver.transfers.ticket('fetch', item.id, 0, 0);
      Future<List<int>> raw(SessionClient peer, String ticket) async {
        final socket = await connectPinned(
          peer.address,
          peer.port,
          peer.host.fingerprint,
        );
        socket.add(
          encodeFrame({
            'type': 'data',
            'deviceId': peer.identity.id,
            'credential': peer.host.credential,
            'role': 'fetch',
            'ticket': ticket,
          }),
        );
        final result = <int>[];
        try {
          await for (final bytes in socket.timeout(
            const Duration(seconds: 5),
          )) {
            result.addAll(bytes);
          }
        } on SocketException {
          /* Rejection may reset instead of closing cleanly. */
        } finally {
          socket.destroy();
        }
        return result;
      }

      expect(await raw(sender, token), isEmpty);
      expect((await raw(receiver, token)).length, 33);
      expect(await raw(receiver, token), isEmpty);
      expect(await raw(receiver, randomSecret(16)), isEmpty);
      final stale = await receiver.transfers.ticket('fetch', item.id, 0, 0);
      host.engine.clear();
      expect(await raw(receiver, stale), isEmpty);
    },
  );
}
