import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows file clipboard uses copy semantics and revision guards',
    (tester) async {
      final clipboard = ClipboardBridge();
      await clipboard.initialize();
      final before = await clipboard.readContent();
      // Do not interfere with an Explorer move already on the clipboard.
      if (before.cut) return;
      final cache = await clipboard.receiveCache();
      expect(await clipboard.availableFileSpace(cache.path), greaterThan(0));
      final directory = await cache.createTemp('native-test-');
      try {
        final file = await File('${directory.path}/report.zip')
            .writeAsBytes([1, 2, 3]);
        await clipboard.inspectFile(file.path);
        // A real stale revision must preserve the existing clipboard.
        expect(
          await clipboard.writeFiles([
            directory.path,
          ], expectedRevision: before.revision + 1),
          false,
        );
        expect((await clipboard.read()).revision, before.revision);
        expect(
          await clipboard.writeFiles([
            directory.path,
          ], expectedRevision: before.revision),
          true,
        );
        final received = await clipboard.readContent();
        expect(received.hasFiles, true);
        expect(received.ownWrite, true);
        expect(received.cut, false);
        expect(received.filePaths, [directory.path]);
        expect(await file.readAsBytes(), [1, 2, 3]);
      } finally {
        if (before.hasFiles && before.filePaths.isNotEmpty) {
          await clipboard.writeFiles(before.filePaths);
        } else if (before.png != null) {
          await clipboard.writeImage(before.png!, text: before.text);
        } else {
          await clipboard.write(before.text ?? '');
        }
        await directory.delete(recursive: true);
      }
    },
  );
}
