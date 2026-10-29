import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/host.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/core/protocol.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

class _PermissionDeniedClipboard extends FakeClipboard {
  @override
  Future<void> ensureNetworkAccess() async {
    throw SessionException('Local-network permission is required.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity certificate;
  late AppController a;
  late AppController b;
  StreamSubscription? approval;

  setUpAll(() {
    certificate = Identity.generate();
  });
  setUp(() async {
    a = await testController(
      Identity('Desktop A', certificate.certificate, certificate.privateKey),
    );
    b = await testController(
      Identity('Desktop B', certificate.certificate, certificate.privateKey),
    );
    await a.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = a.host!.pairing.stream.listen((request) => request.decide(true));
    await b.pair(a.host!.invite().encode());
    await eventually(() => a.connected && b.connected);
  });
  tearDown(() async {
    await approval?.cancel();
    await b.leave();
    await a.leave();
    a.dispose();
    b.dispose();
  });

  test(
    'automatic native events sync both directions without echo loops',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      ca.userCopy('one');
      await eventually(
        () => cb.text == 'one',
        reason: 'First automatic transfer failed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(a.host!.engine.sequence, 1);
      expect(cb.writes, 1);
      cb.userCopy('two');
      await eventually(
        () => ca.text == 'two',
        reason: 'Reverse automatic transfer failed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(a.host!.engine.sequence, 2);
      expect(ca.writes, 1);
      expect(
        a.members.where((d) => d['id'] == b.identity.id).single['status'],
        'applied',
      );
      // Replacement is announced by sender only; the text never appears.
      expect(cb.notices, ['Text from Desktop A is ready to paste.']);
      expect(ca.notices.single, isNot(contains('two')));
    },
  );

  test(
    'code pairing reconnects and copying only the code stays private',
    () async {
      await b.leave();
      a.newInvitation();
      final code = a.host!.pairCode!;
      await a.copyInvitation(code);
      expect((a.clipboard as FakeClipboard).text, code);
      expect(a.host!.engine.item, null);
      await b.pairWithCode(code, '127.0.0.1', a.host!.port);
      await eventually(() => b.connected && b.members.length == 2);
      expect(b.trust.hosts[a.identity.id]!.fingerprint, a.identity.fingerprint);
      await b.sendText('after code pairing');
      await eventually(() => a.item?.text == 'after code pairing');
      expect((a.clipboard as FakeClipboard).text, code);
      expect(a.host!.engine.sequence, 1);
    },
  );

  test(
    'pause prevents clipboard application and resumes for new copies',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      await b.setPaused(true);
      ca.userCopy('while paused');
      await eventually(() => b.item?.text == 'while paused');
      expect(cb.text, null);
      expect(cb.writes, 0);
      await b.setPaused(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      ca.userCopy('after resume');
      await eventually(() => cb.text == 'after resume');
    },
  );

  test(
    'native compare-and-set preserves a copy made during an incoming write',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      cb.beforeWrite = () => cb.userCopy('my fresh local copy');
      ca.userCopy('incoming');
      await eventually(() => cb.text == 'my fresh local copy');
      expect(cb.writes, 0);
      expect(cb.text, 'my fresh local copy');
    },
  );

  test(
    'reconnection snapshot does not replace a newer offline local copy',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      final saved = b.selectedHost!;
      await b.leave();
      ca.userCopy('remote while offline');
      cb.userCopy('local while offline');
      await eventually(() => a.item?.text == 'remote while offline');
      await b.joinSaved(saved);
      await eventually(() => b.item?.text == 'remote while offline');
      expect(cb.text, 'local while offline');
      expect(cb.writes, 0);
      await b.copyReceived();
      expect(cb.text, 'remote while offline');
    },
  );

  test('copies marked private by their app are never sent automatically', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    cb.userCopy('password from a vault', private: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(a.host!.engine.item, null);
    expect(ca.text, null);
    cb.userCopy('ordinary text');
    await eventually(() => ca.text == 'ordinary text');
  });

  test(
    'spoofed discovery for a saved host neither redirects nor unpairs it',
    () async {
      final spoof = LocalHost(
        Identity.generate(),
        TrustStore(MemoryVault()),
        'Desktop A',
      );
      await spoof.start('127.0.0.1', 0);
      addTearDown(spoof.stop);
      final saved = b.selectedHost!;
      final realPort = saved.port;
      await b.leave();
      b.discovery.hosts[a.identity.id] = NearbyHost(
        a.identity.id,
        'Desktop A',
        '127.0.0.1',
        spoof.port,
      );
      await b.joinSaved(saved);
      await eventually(() => b.connected, reason: 'Saved route was not tried');
      expect(b.selectedHost, same(saved));
      expect(saved.port, realPort);
      expect(b.trust.hosts[a.identity.id]!.port, realPort);
    },
  );

  test('rapid copies coalesce to latest current clipboard', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    for (var i = 0; i < 30; i++) {
      ca.userCopy('revision $i');
    }
    await eventually(() => cb.text == 'revision 29');
    expect(a.host!.engine.sequence, 1);
  });

  test('startup reconnection reports denied network permission without an unhandled error', () async {
    final saved = b.selectedHost!;
    await b.preferences.setString('lastHost', saved.id);
    final restored = AppController(
      identity: b.identity,
      trust: b.trust,
      clipboard: _PermissionDeniedClipboard(),
      discovery: FakeDiscovery(),
      preferences: b.preferences,
    );
    try {
      await restored.initialize(discover: false, loadInterfaces: false);
      await eventually(() => restored.error != null);
      expect(restored.error, 'Local-network permission is required.');
      expect(restored.connected, isFalse);
    } finally {
      restored.dispose();
    }
  });

  test(
    'copying an invitation never shares it or lets incoming text replace it',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      await a.copyInvitation('private pairing material');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(a.host!.engine.sequence, 0);
      cb.userCopy('ordinary shared text');
      await eventually(() => a.item?.text == 'ordinary shared text');
      expect(ca.text, 'private pairing material');
      expect(a.host!.engine.item!.text, 'ordinary shared text');
      await a.copyReceived();
      expect(ca.text, 'ordinary shared text');
    },
  );
}
