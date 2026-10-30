import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    for (final controller in [a, b]) {
      final cache = (controller.clipboard as FakeClipboard).fileCache;
      if (cache != null && await cache.exists()) {
        await cache.delete(recursive: true);
      }
    }
    a.dispose();
    b.dispose();
  });

  test(
    'files require consent, preserve nested bytes, and sync both directions',
    () async {
      final ca = a.clipboard as FakeClipboard,
          cb = b.clipboard as FakeClipboard;
      ca.filesEnabled = cb.filesEnabled = true;
      final source = await Directory.systemTemp.createTemp('hopboard-source-');
      addTearDown(() => source.delete(recursive: true));
      final folder = await Directory('${source.path}/Folder').create();
      await Directory('${folder.path}/empty').create();
      await File('${folder.path}/report.zip').writeAsBytes([1, 2, 3, 4]);
      ca.userCopyFiles([folder.path]);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(a.item, null);
      await a.setAutomaticFiles(true);
      await b.setAutomaticFiles(true);
      ca.userCopyFiles([folder.path]);
      await eventually(() => b.itemStatus == 'Ready to paste');
      expect(b.item!.kind, 'files');
      expect(await File('${cb.filePaths.single}/report.zip').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(await Directory('${cb.filePaths.single}/empty').exists(), true);
      expect(a.host!.engine.sequence, 1);
      expect(cb.writes, 1);
      // Use a different root so the second publication is a genuine local copy.
      final other = await File('${source.path}/other.txt')
          .writeAsString('return');
      cb.userCopyFiles([other.path]);
      await eventually(() => a.itemStatus == 'Ready to paste');
      expect(await File(ca.filePaths.single).readAsString(), 'return');
      expect(a.host!.engine.sequence, 2);
      expect(ca.writes, 1);
    },
  );

  test(
    'member download progress is bounded and cleared for the next item',
    () async {
      await a.sendText('progress test');
      await eventually(() => b.item != null);
      final host = a.host!;
      host.receipt(b.identity.id, {
        'itemId': b.item!.id,
        'status': 'downloading',
        'progress': 37,
      });
      await eventually(
        () => b.members.any(
          (m) => m['id'] == b.identity.id && m['progress'] == 37,
        ),
      );
      host.receipt(b.identity.id, {
        'itemId': b.item!.id,
        'status': 'downloading',
        'progress': 101,
      });
      await eventually(
        () => b.members.any(
          (m) => m['id'] == b.identity.id && !m.containsKey('progress'),
        ),
      );
      host.receipt(b.identity.id, {
        'itemId': b.item!.id,
        'status': 'downloading',
        'progress': 40,
      });
      host.engine.clear();
      await eventually(() => b.item == null);
      expect(b.members.every((m) => !m.containsKey('progress')), true);
    },
  );

  test('file consent never enables automatic image sending', () async {
    final ca = a.clipboard as FakeClipboard;
    ca.filesEnabled = true;
    await a.setAutomaticFiles(true);
    ca.userCopyImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(a.item, null);
  });

  test('Cut and sensitive files are not automatically published', () async {
    final ca = a.clipboard as FakeClipboard;
    ca.filesEnabled = true;
    await a.setAutomaticFiles(true);
    ca.userCopyFiles(['unused'], move: true);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(a.item, null);
    await expectLater(a.pasteAndSend(), throwsA(isA<SessionException>()));
    ca.userCopyFiles(['unused'], private: true);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(a.item, null);
  });

  test(
    'large files wait for Download and respect the receiver size limit',
    () async {
      final ca = a.clipboard as FakeClipboard,
          cb = b.clipboard as FakeClipboard;
      ca.filesEnabled = cb.filesEnabled = true;
      final source = await Directory.systemTemp.createTemp('hopboard-large-');
      addTearDown(() => source.delete(recursive: true));
      final file = File('${source.path}/large.bin');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(257 * 1024 * 1024);
      await handle.close();
      await b.setAutomaticFiles(true);
      await a.sendFiles([file.path]);
      await eventually(() => b.item?.kind == 'files');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.imageProgress, null);
      expect(cb.writes, 0);
      expect(cb.fileCache, null);
      await b.setFileLimits(itemBytes: 16 * 1024 * 1024);
      await expectLater(b.copyReceived(), throwsA(isA<SessionException>()));
      expect(cb.writes, 0);
      expect(cb.fileCache, null);
    },
  );

  test(
    'low disk space prevents download and allows retry after space is freed',
    () async {
      final ca = a.clipboard as FakeClipboard,
          cb = b.clipboard as FakeClipboard;
      ca.filesEnabled = cb.filesEnabled = true;
      final source = await Directory.systemTemp.createTemp('hopboard-space-');
      addTearDown(() => source.delete(recursive: true));
      final file = await File('${source.path}/report.txt')
          .writeAsString('content');
      cb.availableBytes = 1024 * 1024 * 1024;
      await b.setAutomaticFiles(true);
      await a.sendFiles([file.path]);
      await eventually(() => b.itemStatus.contains('disk space'));
      expect(cb.writes, 0);
      expect(await cb.fileCache!.list().toList(), isEmpty);
      cb.availableBytes *= 2;
      await b.copyReceived();
      expect(b.itemStatus, 'Ready to paste');
      expect(await File(cb.filePaths.single).readAsString(), 'content');
    },
  );

  test(
    'clearing the cache waits for cancelled downloads and permits retry',
    () async {
      final ca = a.clipboard as FakeClipboard,
          cb = b.clipboard as FakeClipboard;
      ca.filesEnabled = cb.filesEnabled = true;
      final source = await Directory.systemTemp.createTemp('hopboard-clear-');
      addTearDown(() => source.delete(recursive: true));
      final file = await File('${source.path}/file.txt')
          .writeAsString('content');
      cb.receiveGate = Completer<void>();
      await b.setAutomaticFiles(true);
      await a.sendFiles([file.path]);
      await eventually(() => b.imageProgress != null);
      final clearing = b.clearReceivedFiles();
      cb.receiveGate!.complete();
      await clearing;
      expect(cb.writes, 0);
      expect(await cb.fileCache!.list().toList(), isEmpty);
      await b.copyReceived();
      expect(await File(cb.filePaths.single).readAsString(), 'content');
    },
  );

  test('a new local copy cancels a pending file download', () async {
    final ca = a.clipboard as FakeClipboard, cb = b.clipboard as FakeClipboard;
    ca.filesEnabled = cb.filesEnabled = true;
    final source = await Directory.systemTemp.createTemp('hopboard-cancel-');
    addTearDown(() => source.delete(recursive: true));
    final file = await File('${source.path}/file.txt')
        .writeAsString('received');
    cb.receiveGate = Completer<void>();
    await b.setAutomaticFiles(true);
    await a.sendFiles([file.path]);
    await eventually(() => b.imageProgress != null);
    cb.userCopy('newer local copy', private: true);
    await eventually(() => b.imageProgress == null);
    cb.receiveGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cb.text, 'newer local copy');
    expect(cb.writes, 0);
    if (cb.fileCache != null) {
      expect(await cb.fileCache!.list().toList(), isEmpty);
    }
  });

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  test(
    'images require separate consent and sync both directions without echo',
    () async {
      final ca = a.clipboard as FakeClipboard,
          cb = b.clipboard as FakeClipboard;
      ca.userCopyImage(png);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a.host!.engine.item, null);
      await a.setAutomaticImages(true);
      await b.setAutomaticImages(true);
      ca.userCopyImage(png);
      await eventually(
        () => cb.png != null && b.itemStatus == 'Ready to paste',
      );
      expect(cb.png, png);
      expect(b.item!.kind, 'image');
      expect(cb.writes, 1);
      expect(a.host!.engine.sequence, 1);
      cb.userCopyImage(png, text: 'A\tB\n1\t2');
      await eventually(
        () => a.item?.kind == 'mixed' && a.itemStatus == 'Ready to paste',
      );
      expect(ca.png, png);
      expect(ca.text, 'A\tB\n1\t2');
      expect(ca.writes, 1);
      expect(a.host!.engine.sequence, 2);
      expect(ca.notices.last, 'Image from Desktop B is ready to paste.');
    },
  );

  test('manual image sharing works without automatic image consent', () async {
    await b.setAutomatic(false);
    final ca = a.clipboard as FakeClipboard, cb = b.clipboard as FakeClipboard;
    ca.userCopyImage(png, text: 'manual');
    await a.pasteAndSend();
    await eventually(() => b.item?.kind == 'mixed');
    expect(cb.png, null);
    await b.copyReceived();
    expect(cb.png, png);
    expect(cb.text, 'manual');
    expect(b.itemStatus, 'Ready to paste');
  });

  test('sensitive images and newer local copies are preserved', () async {
    await a.setAutomaticImages(true);
    await b.setAutomaticImages(true);
    final ca = a.clipboard as FakeClipboard, cb = b.clipboard as FakeClipboard;
    ca.userCopyImage(png, private: true);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(a.host!.engine.item, null);
    cb.beforeWrite = () => cb.userCopy('newer local copy', private: true);
    ca.userCopyImage(png);
    await eventually(() => b.item?.kind == 'image');
    await eventually(() => cb.text == 'newer local copy');
    expect(cb.png, null);
    expect(b.itemStatus, isNot('Ready to paste'));
    expect(cb.writes, 0);
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

  test(
    'copies marked private by their app are never sent automatically',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      cb.userCopy('password from a vault', private: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(a.host!.engine.item, null);
      expect(ca.text, null);
      cb.userCopy('ordinary text');
      await eventually(() => ca.text == 'ordinary text');
    },
  );

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
