import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

// Received files reach the clipboard at once as virtual files and stream when
// an app pastes them; small items are then upgraded to real files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity certificate;
  late AppController a;
  late AppController b;
  late FakeClipboard ca;
  late FakeClipboard cb;
  late Directory source;
  StreamSubscription? approval;

  setUpAll(() => certificate = Identity.generate());

  setUp(() async {
    a = await testController(
      Identity('Desktop A', certificate.certificate, certificate.privateKey),
      newestWins: true,
    );
    b = await testController(
      Identity('Desktop B', certificate.certificate, certificate.privateKey),
      newestWins: true,
    );
    ca = a.clipboard as FakeClipboard;
    cb = b.clipboard as FakeClipboard;
    ca.filesEnabled = cb.filesEnabled = true;
    cb.virtualEnabled = true;
    await a.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = a.host!.pairing.stream.listen((request) => request.decide(true));
    await b.pair(a.host!.invite().encode());
    await eventually(() => a.connected && b.connected);
    await a.setAutomaticFiles(true);
    await b.setAutomaticFiles(true);
    source = await Directory.systemTemp.createTemp('hopboard-virtual-');
  });

  tearDown(() async {
    await approval?.cancel();
    await b.leave();
    await a.leave();
    for (final clipboard in [ca, cb]) {
      final cache = clipboard.fileCache;
      if (cache != null && await cache.exists()) {
        await cache.delete(recursive: true);
      }
    }
    if (await source.exists()) await source.delete(recursive: true);
    a.dispose();
    b.dispose();
  });

  test('small files appear at once, stream, then become real files', () async {
    final file = await File('${source.path}/clip.mp4').writeAsString('video');
    ca.userCopyFiles([file.path]);
    await eventually(() => b.item?.kind == 'files');
    final id = b.item!.id;
    // Real files replace the virtual ones once the download finishes.
    await eventually(
      () => cb.filePaths.length == 1 && b.itemStatus == 'Ready to paste',
      reason: 'virtual files were not upgraded',
    );
    expect(await File(cb.filePaths.single).readAsString(), 'video');
    final entry = cb.progress[id]![0]!;
    expect(entry.done, isTrue);
    expect(entry.bytes, 5);
    expect(entry.path, cb.filePaths.single);
    expect(cb.failedVirtual, isEmpty);
  });

  test('large files wait on the clipboard until a paste starts', () async {
    await b.setFileLimits(automaticBytes: 1);
    final file = await File('${source.path}/big.mkv').writeAsString('large');
    ca.userCopyFiles([file.path]);
    await eventually(
      () => cb.virtualId != null && b.itemStatus == 'Ready to paste',
      reason: 'virtual files were not placed on the clipboard',
    );
    final id = cb.virtualId!;
    expect(cb.virtualPaths, ['big.mkv']);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cb.fileCache, isNull, reason: 'nothing downloads before a paste');
    cb.pasteVirtual();
    await eventually(
      () => cb.progress[id]?[0]?.done == true,
      reason: 'paste did not start the download',
    );
    await eventually(() => cb.filePaths.length == 1);
    expect(await File(cb.filePaths.single).readAsString(), 'large');
  });

  test('folders keep their structure in the virtual file list', () async {
    await b.setFileLimits(automaticBytes: 1);
    final folder = await Directory('${source.path}/album').create();
    await File('${folder.path}/one.txt').writeAsString('1');
    await Directory('${folder.path}/sub').create();
    await File('${folder.path}/sub/two.txt').writeAsString('22');
    ca.userCopyFiles([folder.path]);
    await eventually(() => cb.virtualId != null);
    expect(cb.virtualPaths.toSet(), {
      'album',
      'album/one.txt',
      'album/sub',
      'album/sub/two.txt',
    });
  });

  test('a newer item makes pending virtual pastes fail fast', () async {
    await b.setFileLimits(automaticBytes: 1);
    final file = await File('${source.path}/old.bin').writeAsString('old');
    ca.userCopyFiles([file.path]);
    await eventually(() => cb.virtualId != null);
    final old = cb.virtualId!;
    ca.userCopy('newer text');
    await eventually(() => cb.text == 'newer text');
    expect(cb.failedVirtual, contains(old));
  });

  test('a local copy on the receiver still wins over a pending item', () async {
    await b.setFileLimits(automaticBytes: 1);
    final file = await File('${source.path}/doc.pdf').writeAsString('pdf');
    ca.userCopyFiles([file.path]);
    await eventually(() => cb.virtualId != null);
    cb.userCopy('my own copy');
    await eventually(() => ca.text == 'my own copy');
    expect(cb.virtualId, isNull);
  });
}
