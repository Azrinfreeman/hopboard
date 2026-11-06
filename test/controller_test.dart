import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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

// Hold only the host controller's acknowledgement; transport and state
// broadcasts still use the real loopback session.
class _HeldAckHost extends LocalHost {
  _HeldAckHost(this.delegate)
    : super(delegate.identity, delegate.trust, delegate.name);
  final LocalHost delegate;
  Map<String, dynamic>? ack;

  @override
  Map<String, dynamic> publish(Map<String, dynamic> message) {
    ack = delegate.publish(message);
    return {'type': 'members', 'devices': <dynamic>[]};
  }

  @override
  void receipt(String id, Map<String, dynamic> message) =>
      delegate.receipt(id, message);
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

  Future<void> restartWithOldText({
    required bool hostReceives,
    bool automatic = true,
    bool private = false,
    bool image = false,
    bool files = false,
    bool unreadable = false,
  }) async {
    await approval?.cancel();
    await b.leave();
    await a.leave();
    a.dispose();
    b.dispose();
    a = await testController(
      Identity('Desktop A', certificate.certificate, certificate.privateKey),
    );
    b = await testController(
      Identity('Desktop B', certificate.certificate, certificate.privateKey),
      automatic: automatic,
    );
    final old = (hostReceives ? a : b).clipboard as FakeClipboard;
    old.text = 'ordinary startup text';
    old.revision = 1;
    old.sensitive = private;
    if (image) old.png = Uint8List.fromList([1]);
    if (files) old.filePaths = ['unused-startup-file'];
    if (unreadable) old.readFailure = PlatformException(code: 'busy');
    await a.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = a.host!.pairing.stream.listen((request) => request.decide(true));
    if (!hostReceives) await a.sendText('initial shared item');
    await b.pair(a.host!.invite().encode());
    await eventually(() => b.connected && b.members.length == 2);
  }

  test(
    'reconnect and duplicate snapshots keep startup text until a fresh item',
    () async {
      await restartWithOldText(hostReceives: false);
      final saved = b.selectedHost!;
      await b.leave();
      await b.joinSaved(saved);
      await eventually(() => b.item?.text == 'initial shared item');
      a.host!.refreshContent();
      expect((b.clipboard as FakeClipboard).text, 'ordinary startup text');
      // The next live state orders the assertion after the duplicate state.
      // Exactly one write below proves the replay did not replace startup text.
      await a.sendText('snapshot barrier');
      await eventually(() => b.item?.text == 'snapshot barrier');
      await eventually(
        () => (b.clipboard as FakeClipboard).text == 'snapshot barrier',
      );
      expect((b.clipboard as FakeClipboard).writes, 1);
    },
  );

  for (final kind in ['private', 'image', 'files', 'unreadable']) {
    test('$kind startup content remains protected from fresh text', () async {
      await restartWithOldText(
        hostReceives: false,
        private: kind == 'private',
        image: kind == 'image',
        files: kind == 'files',
        unreadable: kind == 'unreadable',
      );
      await a.sendText('fresh remote');
      await eventually(() => b.item?.text == 'fresh remote');
      final cb = b.clipboard as FakeClipboard;
      expect(cb.text, 'ordinary startup text');
      expect(cb.writes, 0);
      expect(
        b.itemStatus,
        contains(
          kind == 'unreadable'
              ? 'could not be checked'
              : 'local copy is protected',
        ),
      );
    });
  }

  test(
    'first automatic enable preserves displayed item then accepts fresh text',
    () async {
      await restartWithOldText(hostReceives: false, automatic: false);
      final cb = b.clipboard as FakeClipboard;
      await b.setAutomatic(true);
      expect(cb.text, 'ordinary startup text');
      expect(cb.writes, 0);
      await a.sendText('fresh after enable');
      await eventually(() => cb.text == 'fresh after enable');
      await b.setAutomatic(false);
      cb.userCopy('copied while automatic was off');
      await b.setAutomatic(true);
      // A repeated baseline must not forget the intervening local edit.
      await b.setAutomaticImages(true);
      await a.sendText('remote after re-enable');
      await eventually(() => b.item?.text == 'remote after re-enable');
      expect(cb.text, 'copied while automatic was off');
      expect(b.itemStatus, contains('sharing was inactive'));
    },
  );

  test('paused local copy stays protected across repeated baselines', () async {
    final cb = b.clipboard as FakeClipboard;
    await b.setPaused(true);
    cb.userCopy('copied while paused');
    await b.setPaused(false);
    await b.setAutomaticImages(true);
    await a.sendText('after paused edit');
    await eventually(() => b.item?.text == 'after paused edit');
    expect(cb.text, 'copied while paused');
    expect(cb.writes, 0);
    await b.copyReceived();
    await a.sendText('after explicit resolution');
    await eventually(() => cb.text == 'after explicit resolution');
  });

  test(
    'delayed baseline cannot commit after automatic sharing is disabled',
    () async {
      final cb = b.clipboard as FakeClipboard;
      cb.readGate = Completer<void>();
      final before = cb.readAttempts;
      final enable = b.setAutomatic(true);
      await eventually(() => cb.readAttempts > before);
      await b.setAutomatic(false);
      cb.userCopy('copy during delayed baseline');
      cb.readGate!.complete();
      await enable;
      cb.readGate = null;
      await b.setAutomatic(true);
      await a.sendText('remote after delayed baseline');
      await eventually(() => b.item?.text == 'remote after delayed baseline');
      expect(cb.text, 'copy during delayed baseline');
      expect(cb.writes, 0);
    },
  );

  for (final classifyBeforeAck in [false, true]) {
    test(
      'stale ack preserves newer private copy (classified: $classifyBeforeAck)',
      () async {
        final original = a.host!;
        final held = _HeldAckHost(original);
        a.host = held;
        addTearDown(() => a.host = original);
        final ca = a.clipboard as FakeClipboard;
        ca.userCopy('in-flight publication');
        await eventually(() => held.ack != null);
        if (!classifyBeforeAck) ca.readGate = Completer<void>();
        final before = ca.readAttempts;
        ca.userCopy('new private copy', private: true);
        await eventually(() => ca.readAttempts > before);
        if (classifyBeforeAck) {
          await eventually(() => a.itemStatus == 'Local clipboard changed');
        }
        original.events.add(held.ack!);
        await b.sendText('remote after stale ack');
        await eventually(() => a.item?.text == 'remote after stale ack');
        if (!classifyBeforeAck) {
          ca.readGate!.complete();
          ca.readGate = null;
        }
        expect(ca.text, 'new private copy');
        expect(ca.writes, 0);
        expect(a.itemStatus, isNot('Ready to paste'));
      },
    );
  }

  for (final hostReceives in [false, true]) {
    test(
      'old startup text accepts fresh copies (host: $hostReceives)',
      () async {
        await restartWithOldText(hostReceives: hostReceives);
        final receiver = hostReceives ? a : b;
        final sender = hostReceives ? b : a;
        final clipboard = receiver.clipboard as FakeClipboard;
        expect(clipboard.text, 'ordinary startup text');
        expect(clipboard.writes, 0);
        expect(a.host!.engine.sequence, hostReceives ? 0 : 1);
        for (final text in ['first fresh copy', 'second fresh copy']) {
          (sender.clipboard as FakeClipboard).userCopy(text);
          await eventually(() => receiver.item?.text == text);
          await eventually(() => clipboard.text == text);
          await eventually(() => receiver.itemStatus == 'Ready to paste');
        }
        expect(clipboard.writes, 2);
        expect(a.host!.engine.sequence, hostReceives ? 2 : 3);
      },
    );
  }

  test('matching ack releases only pending-publication protection', () async {
    final original = a.host!;
    final held = _HeldAckHost(original);
    a.host = held;
    addTearDown(() => a.host = original);
    (a.clipboard as FakeClipboard).userCopy('my publication');
    await eventually(() => held.ack != null);
    await eventually(() => b.item?.text == 'my publication');
    await b.sendText('overlapping remote item');
    await eventually(() => a.item?.text == 'overlapping remote item');
    expect((a.clipboard as FakeClipboard).text, 'my publication');
    expect(a.itemStatus, 'Waiting for your local copy to finish sending.');
    original.events.add(held.ack!);
    await eventually(() => !a.hasConflict);
    expect(a.itemStatus, 'Available in app. Waiting for the next shared copy.');
    await b.sendText('fresh remote after ack');
    await eventually(() => a.item?.text == 'fresh remote after ack');
    await eventually(
      () => (a.clipboard as FakeClipboard).text == 'fresh remote after ack',
    );
  });

  test('rejected publication cannot be resolved by a late ack', () async {
    final original = a.host!;
    final held = _HeldAckHost(original);
    a.host = held;
    addTearDown(() => a.host = original);
    final ca = a.clipboard as FakeClipboard;
    ca.userCopy('conflicting local copy');
    await eventually(() => held.ack != null);
    original.events.add({
      'type': 'error',
      'code': 'conflict',
      'message': 'Resolve simultaneous sends.',
      'requestId': held.ack!['requestId'],
    });
    await eventually(() => a.hasConflict);
    original.events.add(held.ack!);
    await b.sendText('remote after rejected publication');
    await eventually(() => a.item?.text == 'remote after rejected publication');
    expect(ca.text, 'conflicting local copy');
    expect(ca.writes, 0);
    expect(a.hasConflict, true);
  });

  test('startup relaxation preserves a newer native revision', () async {
    await restartWithOldText(hostReceives: false);
    final cb = b.clipboard as FakeClipboard;
    cb.beforeWrite = () =>
        cb.userCopy('private copy during startup write', private: true);
    await a.sendText('fresh text against startup baseline');
    await eventually(() => cb.text == 'private copy during startup write');
    expect(cb.writes, 0);
    expect(b.itemStatus, isNot('Ready to paste'));
  });

  test(
    'first successful baseline cannot erase an explicit typed-send conflict',
    () async {
      await restartWithOldText(hostReceives: true, unreadable: true);
      final original = a.host!;
      final held = _HeldAckHost(original);
      a.host = held;
      addTearDown(() => a.host = original);
      await a.sendText('typed send with unreadable clipboard');
      original.events.add({
        'type': 'error',
        'code': 'conflict',
        'message': 'Resolve simultaneous sends.',
        'requestId': held.ack!['requestId'],
      });
      await eventually(() => a.hasConflict);
      final ca = a.clipboard as FakeClipboard;
      ca.readFailure = null;
      await a.setAutomaticImages(true);
      await b.sendText('fresh remote after baseline recovery');
      await eventually(
        () => a.item?.text == 'fresh remote after baseline recovery',
      );
      expect(ca.text, 'ordinary startup text');
      expect(ca.writes, 0);
      expect(a.hasConflict, true);
    },
  );

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
      expect(b.itemStatus, contains('Above your automatic download limit'));
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

  test('incoming image explains that automatic image sharing is off', () async {
    final ca = a.clipboard as FakeClipboard;
    ca.userCopyImage(png);
    await a.pasteAndSend();
    await eventually(() => b.item?.kind == 'image');
    expect(
      b.itemStatus,
      'Automatic image sharing is off. Copy to use this image.',
    );
    expect((b.clipboard as FakeClipboard).writes, 0);
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

  test('two host copies are confirmed ready without manual Copy', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    for (final text in ['first host copy', 'second host copy']) {
      ca.userCopy(text);
      await eventually(
        () => cb.text == text && b.itemStatus == 'Ready to paste',
      );
      await eventually(
        () =>
            a.members
                .where((member) => member['id'] == b.identity.id)
                .single['status'] ==
            'applied',
      );
      expect(b.item?.text, text);
      expect(b.textReadyToPaste, isTrue);
    }
    expect(cb.writes, 2);
    expect(a.host!.engine.sequence, 2);
    cb.userCopy('private local replacement', private: true);
    await eventually(() => b.itemStatus == 'Local clipboard changed');
    expect(b.textReadyToPaste, isFalse);
    await b.leave();
    expect(b.textReadyToPaste, isFalse);
  });

  test(
    'receiver enables once then fresh host copies apply automatically',
    () async {
      await b.setAutomatic(false);
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      ca.userCopy('visible while receiver is off');
      await eventually(() => b.item?.text == 'visible while receiver is off');
      expect(cb.text, isNull);
      expect(cb.writes, 0);
      await b.setAutomatic(true);
      expect(cb.writes, 0);
      for (final text in ['fresh after consent', 'another fresh copy']) {
        ca.userCopy(text);
        await eventually(
          () => cb.text == text && b.itemStatus == 'Ready to paste',
        );
      }
      expect(cb.writes, 2);
    },
  );

  for (final change in ['pause', 'automatic mode']) {
    test(
      '$change clears confirmed readiness until a fresh host copy',
      () async {
        final ca = a.clipboard as FakeClipboard;
        final cb = b.clipboard as FakeClipboard;
        ca.userCopy('confirmed before change');
        await eventually(() => b.itemStatus == 'Ready to paste');
        if (change == 'pause') {
          await b.setPaused(true);
        } else {
          await b.setAutomatic(false);
        }
        expect(b.itemStatus, isNot('Ready to paste'));
        if (change == 'pause') {
          await b.setPaused(false);
        } else {
          await b.setAutomatic(true);
        }
        expect(b.itemStatus, isNot('Ready to paste'));
        expect(cb.writes, 1);
        ca.userCopy('confirmed after change');
        await eventually(() => cb.text == 'confirmed after change');
        expect(b.itemStatus, 'Ready to paste');
      },
    );
  }

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

  test('one copy recovers after clipboard capture is busy for 600ms', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    ca.readBusyUntil = DateTime.now().add(const Duration(milliseconds: 600));
    ca.userCopy('recover capture');
    await eventually(() => cb.text == 'recover capture');
    expect(a.host!.engine.sequence, 1);
    expect(cb.writes, 1);
  });

  for (final kind in ['text', 'image', 'files']) {
    test(
      '$kind confirmation retries reads without repeating a successful write',
      () async {
        final ca = a.clipboard as FakeClipboard;
        final cb = b.clipboard as FakeClipboard;
        if (kind == 'image') {
          await a.setAutomaticImages(true);
          await b.setAutomaticImages(true);
        }
        if (kind == 'files') {
          ca.filesEnabled = cb.filesEnabled = true;
          await a.setAutomaticFiles(true);
          await b.setAutomaticFiles(true);
        }
        cb.busyAfterWrite = const Duration(milliseconds: 600);
        if (kind == 'image') {
          ca.userCopyImage(png);
        } else if (kind == 'files') {
          final directory = await Directory.systemTemp.createTemp(
            'clipboard-retry-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = await File('${directory.path}/video.mp4')
              .writeAsBytes([1, 2, 3]);
          ca.userCopyFiles([file.path]);
        } else {
          ca.userCopy('confirm once');
        }
        await eventually(() => b.itemStatus == 'Ready to paste');
        expect(cb.writes, 1);
        expect(cb.writeAttempts, 1);
        expect(a.host!.engine.sequence, 1);
        ca.userCopy('next automatic copy');
        await eventually(() => cb.text == 'next automatic copy');
        await eventually(() => b.itemStatus == 'Ready to paste');
        expect(cb.writes, 2);
        expect(a.host!.engine.sequence, 2);
      },
    );
  }

  test(
    'a pending candidate waits for classification of a newer private copy',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final attempts = ca.readAttempts;
      ca.userCopy('old candidate');
      await eventually(() => ca.readAttempts > attempts);
      // Keep the next read blocked past the candidate's coalescing timer.
      ca.readGate = Completer<void>();
      ca.userCopy('new private copy', private: true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(a.host!.engine.sequence, 0);
      ca.readGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(a.host!.engine.sequence, 0);
      ca.readGate = null;
    },
  );

  test(
    'duplicate notifications do not discard an eligible candidate',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final attempts = ca.readAttempts;
      ca.userCopy('one revision');
      await eventually(() => ca.readAttempts > attempts);
      ca.changes.add(null);
      await eventually(
        () => (b.clipboard as FakeClipboard).text == 'one revision',
      );
      expect(a.host!.engine.sequence, 1);
    },
  );

  test('capture recovery uses the newest eligible copy', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    ca.readBusyUntil = DateTime.now().add(const Duration(milliseconds: 600));
    ca.userCopy('superseded');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    ca.userCopy('latest copy');
    await eventually(() => cb.text == 'latest copy');
    expect(a.host!.engine.sequence, 1);
  });

  test('capture recovery never sends a newer private copy', () async {
    final ca = a.clipboard as FakeClipboard;
    ca.readBusyUntil = DateTime.now().add(const Duration(milliseconds: 600));
    ca.userCopy('superseded');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    ca.userCopy('secret', private: true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(a.host!.engine.sequence, 0);
    ca.userCopy('public');
    await eventually(() => (b.clipboard as FakeClipboard).text == 'public');
  });

  test(
    'pausing cancels a pending capture even after sharing resumes',
    () async {
      final ca = a.clipboard as FakeClipboard;
      ca.readBusyUntil = DateTime.now().add(const Duration(milliseconds: 600));
      ca.userCopy('before pause');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await a.setPaused(true);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await a.setPaused(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a.host!.engine.sequence, 0);
      ca.userCopy('after resume');
      await eventually(
        () => (b.clipboard as FakeClipboard).text == 'after resume',
      );
    },
  );

  test('permanent capture errors are reported without retrying', () async {
    final ca = a.clipboard as FakeClipboard;
    final attempts = ca.readAttempts;
    ca.readFailure = PlatformException(
      code: 'image',
      message: 'Unsupported image',
    );
    ca.userCopy('invalid image');
    await eventually(() => a.error != null);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(ca.readAttempts, attempts + 1);
    expect(a.host!.engine.sequence, 0);
    ca.readFailure = null;
    ca.userCopy('valid copy');
    await eventually(() => (b.clipboard as FakeClipboard).text == 'valid copy');
  });

  test(
    'capture retries stop after the deadline and a fresh copy recovers',
    () async {
      final ca = a.clipboard as FakeClipboard;
      ca.readBusyUntil = DateTime.now().add(const Duration(seconds: 10));
      ca.userCopy('blocked');
      await Future<void>.delayed(const Duration(milliseconds: 5400));
      expect(a.error, contains('Clipboard stayed busy'));
      final attempts = ca.readAttempts;
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(ca.readAttempts, attempts);
      ca.readBusyUntil = null;
      ca.userCopy('retry succeeds');
      await eventually(
        () => (b.clipboard as FakeClipboard).text == 'retry succeeds',
      );
      expect(a.error, isNull);
    },
  );

  test(
    'failed confirmation reconciles before the next automatic write',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      cb.busyAfterWrite = const Duration(seconds: 10);
      ca.userCopy('unconfirmed');
      await eventually(() => cb.writes == 1);
      await Future<void>.delayed(const Duration(milliseconds: 5400));
      expect(b.itemStatus, contains('Clipboard confirmation failed'));
      expect(b.textReadyToPaste, isFalse);
      cb.readBusyUntil = null;
      ca.userCopy('next confirmed');
      await eventually(() => b.itemStatus == 'Ready to paste');
      expect(cb.text, 'next confirmed');
      expect(cb.writeAttempts, 2);
    },
  );

  test(
    'a newer incoming item cancels confirmation of the previous item',
    () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      cb.busyAfterWrite = const Duration(milliseconds: 600);
      ca.userCopy('previous item');
      await eventually(() => cb.writes == 1);
      ca.userCopy('new current item');
      await eventually(() => cb.text == 'new current item');
      await eventually(() => b.itemStatus == 'Ready to paste');
      expect(cb.writeAttempts, 2);
    },
  );

  test('manual Copy retries confirmation without writing twice', () async {
    await b.setAutomatic(false);
    final cb = b.clipboard as FakeClipboard;
    await a.sendText('manual confirmation');
    await eventually(() => b.item != null);
    cb.busyAfterWrite = const Duration(milliseconds: 600);
    await b.copyReceived();
    expect(b.itemStatus, 'Ready to paste');
    expect(cb.writeAttempts, 1);
  });

  test('local copy during confirmation remains protected', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    cb.busyAfterWrite = const Duration(milliseconds: 600);
    ca.userCopy('incoming');
    await eventually(() => cb.writes == 1);
    cb.userCopy('new local secret', private: true);
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(cb.text, 'new local secret');
    expect(b.itemStatus, isNot('Ready to paste'));
    ca.userCopy('another incoming');
    await eventually(() => b.item?.text == 'another incoming');
    expect(cb.text, 'new local secret');
    expect(b.itemStatus, contains('local copy is protected'));
    await b.copyReceived();
    ca.userCopy('resolved');
    await eventually(() => cb.text == 'resolved');
  });

  test('a published local copy resolves an interrupted confirmation', () async {
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    cb.busyAfterWrite = const Duration(milliseconds: 600);
    ca.userCopy('incoming before local copy');
    await eventually(() => cb.writes == 1);
    cb.userCopy('ordinary local copy');
    await eventually(() => ca.text == 'ordinary local copy');
    ca.userCopy('incoming after local publication');
    await eventually(() => cb.text == 'incoming after local publication');
    await eventually(() => b.itemStatus == 'Ready to paste');
  });

  test('incoming clipboard writes retry transient busy failures', () async {
    final cb = b.clipboard as FakeClipboard;
    cb.busyWrites = 5;
    (a.clipboard as FakeClipboard).userCopy('busy write');
    await eventually(() => b.itemStatus == 'Ready to paste');
    expect(cb.text, 'busy write');
    expect(cb.writeAttempts, 6);
    expect(cb.writes, 1);
  });

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
