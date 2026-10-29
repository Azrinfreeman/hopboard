import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/client.dart';
import 'package:local_clipboard/core/framing.dart';
import 'package:local_clipboard/core/host.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/core/protocol.dart';

Future<Map<String, dynamic>> message(SessionClient client, String type) =>
    client.events.stream
        .firstWhere((m) => m['type'] == type)
        .timeout(const Duration(seconds: 5));

void main() {
  late Identity identity;
  setUpAll(() async {
    identity = Identity.generate();
  });

  test(
    'real pinned TLS: pair, broadcast, deduplicate, conflict, revoke',
    () async {
      final trust = TrustStore(MemoryVault());
      final host = LocalHost(identity, trust, 'Host');
      await host.start('127.0.0.1', 0);
      final approval = host.pairing.stream.listen(
        (request) => request.decide(true),
      );
      final firstIdentity = Identity(
        'client-a',
        identity.certificate,
        identity.privateKey,
      );
      final secondIdentity = Identity(
        'client-b',
        identity.certificate,
        identity.privateKey,
      );
      final savedA = await SessionClient.pair(
        firstIdentity,
        'Alice',
        host.invite(),
      );
      final savedB = await SessionClient.pair(
        secondIdentity,
        'Bob',
        host.invite(),
      );
      final a = SessionClient(firstIdentity, savedA);
      final b = SessionClient(secondIdentity, savedB);
      addTearDown(() async {
        a.stop();
        b.stop();
        await approval.cancel();
        await host.stop();
      });
      final initialA = message(a, 'state');
      final initialB = message(b, 'state');
      await a.connect();
      await b.connect();
      await initialA;
      await initialB;
      final publication = {
        'type': 'publish',
        'requestId': 'publish-one',
        'epoch': host.engine.epoch,
        'baseSeq': 0,
        'text': 'Hello 👋\nAcross devices',
        'senderId': 'spoofed',
      };
      final ack = message(a, 'ack');
      final received = message(b, 'state');
      await a.send(publication);
      expect((await ack)['seq'], 1);
      final item = (await received)['item'] as Map;
      expect(item['text'], publication['text']);
      expect(item['senderId'], 'client-a');
      final duplicateAck = message(a, 'ack');
      await a.send(publication);
      await duplicateAck;
      expect(host.engine.sequence, 1);
      final conflict = message(b, 'error');
      await b.send({...publication, 'requestId': 'b-one', 'text': 'competing'});
      expect((await conflict)['code'], 'conflict');
      expect(host.engine.item!.text, publication['text']);
      final gone = message(a, 'disconnected');
      await host.revoke('client-a');
      await gone;
      final revoked = SessionClient(firstIdentity, savedA);
      addTearDown(revoked.stop);
      await expectLater(revoked.connect(), throwsA(isA<SessionException>()));
      expect(trust.devices.containsKey('client-a'), false);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('wrong certificate pin fails before credentials are sent', () async {
    final host = LocalHost(identity, TrustStore(MemoryVault()), 'Host');
    await host.start('127.0.0.1', 0);
    addTearDown(host.stop);
    await expectLater(
      connectPinned('127.0.0.1', host.port, '0' * 64),
      throwsA(
        isA<SessionException>().having(
          (error) => error.code,
          'code',
          'certificate',
        ),
      ),
    );
  });

  test(
    'six-digit pairing waits for approval and saves a usable certificate pin',
    () async {
      final trust = TrustStore(MemoryVault());
      final host = LocalHost(identity, trust, 'Code host');
      await host.start('127.0.0.1', 0);
      addTearDown(host.stop);
      final invite = host.invite();
      final code = host.pairCode!;
      final requested = host.pairing.stream.first;
      final clientIdentity = Identity(
        'code-client',
        identity.certificate,
        identity.privateKey,
      );
      final pairing = SessionClient.pairWithCode(
        clientIdentity,
        'PC two',
        '127.0.0.1',
        host.port,
        code,
      );
      final request = await requested;
      expect(trust.devices, isEmpty);
      request.decide(true);
      final saved = await pairing;
      expect(saved.fingerprint, invite.fingerprint);
      expect(saved.id, identity.id);
      expect(host.pairCode, null);
      final client = SessionClient(clientIdentity, saved);
      addTearDown(client.stop);
      await client.connect();
      await expectLater(
        SessionClient.pairWithCode(
          clientIdentity,
          'PC two',
          '127.0.0.1',
          host.port,
          code,
        ),
        throwsA(isA<SessionException>()),
      );
      await expectLater(
        SessionClient.pair(clientIdentity, 'PC two', invite),
        throwsA(isA<SessionException>()),
      );
    },
  );

  test('wrong codes never request approval; one device is capped at three attempts but QR still works', () async {
    final trust = TrustStore(MemoryVault());
    final host = LocalHost(identity, trust, 'Host');
    await host.start('127.0.0.1', 0);
    var approvals = 0;
    final sub = host.pairing.stream.listen((request) {
      approvals++;
      request.decide(true);
    });
    addTearDown(() async {
      await sub.cancel();
      await host.stop();
    });
    final invite = host.invite();
    final client = Identity(
      'code-client',
      identity.certificate,
      identity.privateKey,
    );
    final wrong = host.pairCode == '000000' ? '000001' : '000000';
    for (var i = 0; i < 3; i++) {
      await expectLater(
        SessionClient.pairWithCode(client, 'PC', '127.0.0.1', host.port, wrong),
        throwsA(isA<SessionException>()),
      );
    }
    // The correct code is now refused from this device.
    await expectLater(
      SessionClient.pairWithCode(
        client,
        'PC',
        '127.0.0.1',
        host.port,
        host.pairCode!,
      ),
      throwsA(isA<SessionException>()),
    );
    expect(approvals, 0);
    expect(trust.devices, isEmpty);
    await SessionClient.pair(client, 'PC', invite);
    expect(approvals, 1);
  });

  test('unauthenticated sockets from one address cannot take every slot', () async {
    final host = LocalHost(identity, TrustStore(MemoryVault()), 'Host');
    await host.start('127.0.0.1', 0);
    addTearDown(host.stop);
    Future<SecureSocket> open() => SecureSocket.connect(
      '127.0.0.1',
      host.port,
      onBadCertificate: (_) => true,
    );
    final idle = [for (var i = 0; i < 3; i++) await open()];
    addTearDown(() {
      for (final socket in idle) {
        socket.destroy();
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final extra = await open();
    // Refused immediately, well before the five-second authentication limit.
    await extra.drain<void>().timeout(const Duration(seconds: 2));
  });

  test('real TLS proxy cannot relay code pairing through a substituted certificate', () async {
    final trust = TrustStore(MemoryVault());
    final host = LocalHost(identity, trust, 'Host');
    await host.start('127.0.0.1', 0);
    host.invite();
    final rogue = Identity.generate();
    final proxy = await SecureServerSocket.bind(
      '127.0.0.1',
      0,
      rogue.context(),
    );
    final connections = <FramedConnection>[];
    var approvals = 0;
    final approval = host.pairing.stream.listen((request) {
      approvals++;
      request.decide(true);
    });
    final listener = proxy.listen((socket) async {
      final downstream = FramedConnection(socket);
      connections.add(downstream);
      final upstream = FramedConnection(
        await connectPinned('127.0.0.1', host.port, identity.fingerprint),
      );
      connections.add(upstream);
      downstream.messages.listen(upstream.post, onDone: upstream.close);
      upstream.messages.listen((message) {
        downstream.post(
          message['type'] == 'codeChallenge'
              ? {...message, 'fingerprint': rogue.fingerprint}
              : message,
        );
      }, onDone: downstream.close);
    });
    addTearDown(() async {
      for (final connection in connections) {
        connection.close();
      }
      await approval.cancel();
      await listener.cancel();
      await proxy.close();
      await host.stop();
    });
    final client = Identity(
      'victim',
      identity.certificate,
      identity.privateKey,
    );
    await expectLater(
      SessionClient.pairWithCode(
        client,
        'PC',
        '127.0.0.1',
        proxy.port,
        host.pairCode!,
      ),
      throwsA(isA<SessionException>()),
    );
    expect(approvals, 0);
    expect(trust.devices, isEmpty);
  });

  test('cancelled codes and host rejection never grant trust', () async {
    final trust = TrustStore(MemoryVault());
    final host = LocalHost(identity, trust, 'Host');
    await host.start('127.0.0.1', 0);
    final sub = host.pairing.stream.listen((request) => request.decide(false));
    addTearDown(() async {
      await sub.cancel();
      await host.stop();
    });
    host.invite();
    final old = host.pairCode!;
    host.cancelInvite();
    final client = Identity(
      'code-client',
      identity.certificate,
      identity.privateKey,
    );
    await expectLater(
      SessionClient.pairWithCode(client, 'PC', '127.0.0.1', host.port, old),
      throwsA(isA<SessionException>()),
    );
    host.invite();
    await expectLater(
      SessionClient.pairWithCode(
        client,
        'PC',
        '127.0.0.1',
        host.port,
        host.pairCode!,
      ),
      throwsA(isA<SessionException>()),
    );
    expect(trust.devices, isEmpty);
  });

  test(
    'one-time invitation cannot be reused and rejected pairing grants no trust',
    () async {
      final trust = TrustStore(MemoryVault());
      final host = LocalHost(identity, trust, 'Host');
      await host.start('127.0.0.1', 0);
      final approval = host.pairing.stream.listen(
        (request) => request.decide(request.name == 'Allowed'),
      );
      addTearDown(() async {
        await approval.cancel();
        await host.stop();
      });
      final client = Identity(
        'allowed',
        identity.certificate,
        identity.privateKey,
      );
      final invite = host.invite();
      await SessionClient.pair(client, 'Allowed', invite);
      await expectLater(
        SessionClient.pair(client, 'Allowed', invite),
        throwsA(isA<SessionException>()),
      );
      final rejected = Identity(
        'rejected',
        identity.certificate,
        identity.privateKey,
      );
      await expectLater(
        SessionClient.pair(rejected, 'Denied', host.invite()),
        throwsA(isA<SessionException>()),
      );
      expect(trust.devices.keys, ['allowed']);
    },
  );

  test(
    'host rebinding retains authoritative session identity and state',
    () async {
      final host = LocalHost(identity, TrustStore(MemoryVault()), 'Host');
      await host.start('127.0.0.1', 0);
      addTearDown(host.stop);
      final epoch = host.engine.epoch;
      host.publish({
        'requestId': 'one',
        'epoch': epoch,
        'baseSeq': 0,
        'text': 'retained',
      });
      await host.rebind('127.0.0.1');
      expect(host.engine.epoch, epoch);
      expect(host.engine.item!.text, 'retained');
    },
  );
}
