import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';

// Real Windows clipboard checks for virtual files and formatted text. The
// previous clipboard content is restored afterwards.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The native listener can be registered once per process.
  final clipboard = ClipboardBridge();
  setUpAll(clipboard.initialize);

  // Other clipboard listeners briefly hold the clipboard after each write; the
  // app retries "busy" the same way.
  Future<T> retry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on PlatformException catch (failure) {
        if (failure.code != 'busy' || attempt >= 20) rethrow;
        debugPrint('busy retry $attempt');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> restore(ClipboardBridge clipboard, ClipboardSnapshot before) {
    if (before.hasFiles && before.filePaths.isNotEmpty) {
      return clipboard.writeFiles(before.filePaths);
    }
    if (before.png != null) {
      return clipboard.writeImage(before.png!, text: before.text);
    }
    return clipboard.write(before.text ?? '');
  }

  testWidgets('virtual files are own writes and upgrade to real files', (
    tester,
  ) async {
    final before = await clipboard.readContent();
    if (before.cut) return; // Leave an Explorer move alone.
    final cache = await clipboard.receiveCache();
    final directory = await cache.createTemp('virtual-test-');
    try {
      final manifest = FileManifest.fromJson({
        'totalBytes': 3,
        'fileCount': 1,
        'roots': ['clip.bin'],
        'entries': [
          {'i': 0, 'path': 'clip.bin', 'size': 3},
        ],
      });
      // A stale revision preserves the clipboard.
      expect(
        await clipboard.writeVirtualFiles(
          'item-1',
          manifest,
          expectedRevision: before.revision + 1,
        ),
        false,
      );
      expect(
        await clipboard.writeVirtualFiles(
          'item-1',
          manifest,
          expectedRevision: before.revision,
        ),
        true,
      );
      final placed = await retry(
        () => clipboard.readContent(includeImages: false),
      );
      expect(placed.ownWrite, true, reason: 'own virtual write not detected');
      expect(placed.hasFiles, false);
      expect(placed.text, isNull);

      final file = await File('${directory.path}/clip.bin')
          .writeAsBytes([1, 2, 3]);
      await clipboard.virtualFileProgress(
        'item-1',
        entry: 0,
        path: file.path,
        available: 3,
        done: true,
      );
      // Upgrade even though the revision we pass is stale.
      expect(
        await retry(
          () => clipboard.writeFiles(
            [file.path],
            expectedRevision: placed.revision - 1,
            replaceVirtual: 'item-1',
          ),
        ),
        true,
      );
      final upgraded = await retry(
        () => clipboard.readContent(includeImages: false),
      );
      expect(upgraded.ownWrite, true);
      expect(upgraded.filePaths, [file.path]);

      // Clearing a superseded item never touches the current clipboard.
      expect(await clipboard.clearVirtualFiles('item-1'), false);
      expect(
        (await retry(() => clipboard.readContent(includeImages: false)))
            .filePaths,
        [file.path],
      );
    } finally {
      await restore(clipboard, before);
      await directory.delete(recursive: true);
    }
  });

  testWidgets('formatted text round-trips through the Windows clipboard', (
    tester,
  ) async {
    final before = await clipboard.readContent();
    if (before.cut) return;
    const html =
        'Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000199\r\n'
        'StartFragment:0000000141\r\nEndFragment:0000000163\r\n'
        '<html><body><!--StartFragment--><b>Bold é</b><!--EndFragment--></body></html>';
    const rtf = r'{\rtf1\ansi {\b Bold}}';
    try {
      expect(await clipboard.write('Bold é', html: html, rtf: rtf), true);
      final read = await retry(() => clipboard.read(includeRich: true));
      expect(read.text, 'Bold é');
      expect(read.html, html);
      expect(read.rtf, rtf);
      expect(await clipboard.write('plain'), true);
      final plain = await retry(() => clipboard.read(includeRich: true));
      expect(plain.html, isNull);
      expect(plain.rtf, isNull);
    } finally {
      await restore(clipboard, before);
    }
  });
}
