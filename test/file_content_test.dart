import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive_io.dart' show ZipDecoder;
import 'package:local_clipboard/core/zip_content.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/core/file_content.dart';

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('hopboard-files-');
  });
  tearDown(() => workspace.delete(recursive: true));

  test(
    'nested directories, empty files, resume and timestamps survive',
    () async {
      final folder = await Directory('${workspace.path}/Source').create();
      await Directory('${folder.path}/empty').create();
      await File('${folder.path}/zero').writeAsBytes([]);
      final original = await File('${folder.path}/bytes')
          .writeAsBytes([0, 1, 2, 255]);
      final content = await FileContent.create([folder.path]);
      final entry = content.payload.files!.entries.singleWhere(
        (e) => e.path.endsWith('/bytes'),
      );
      expect(await content.open(entry.index, 2).expand((e) => e).toList(), [
        2,
        255,
      ]);
      final result = await ReceivedFiles.receive(
        Directory('${workspace.path}/cache'),
        content.payload.files!,
        (index, write) async {
          await for (final chunk in content.open(index, 0)) {
            await write(chunk);
          }
        },
        check: () {},
      );
      expect(await Directory('${result.roots.single}/empty').exists(), true);
      expect(await File('${result.roots.single}/zero').length(), 0);
      expect(await File('${result.roots.single}/bytes').readAsBytes(), [
        0,
        1,
        2,
        255,
      ]);
      expect(
        (await File(
          '${result.roots.single}/bytes',
        ).stat()).modified.millisecondsSinceEpoch,
        (await original.stat()).modified.millisecondsSinceEpoch,
      );
      await result.delete();
      expect(await result.directory.exists(), false);
    },
  );

  test(
    'source edits and duplicate roots fail before exposing content',
    () async {
      final file = await File('${workspace.path}/a').writeAsString('first');
      final content = await FileContent.create([file.path]);
      await file.writeAsString('changed');
      await expectLater(content.open(0, 0).drain<void>(), throwsException);
      await expectLater(
        FileContent.create([file.path, file.path]),
        throwsFormatException,
      );
    },
  );

  test(
    'cancelled, short, oversized and corrupt transfers leave no cache item',
    () async {
      final manifest = FileManifest.fromJson({
        'entries': [
          {'i': 0, 'path': 'a', 'size': 2},
        ],
        'roots': ['a'],
        'totalBytes': 2,
        'fileCount': 1,
      });
      final cache = await Directory('${workspace.path}/cache').create();
      for (final count in [1, 3, 2]) {
        await expectLater(
          ReceivedFiles.receive(cache, manifest, (_, write) async {
            await write(List.filled(count, 0));
            if (count == 2) throw const FormatException('Invalid stream hash');
          }, check: () {}),
          throwsFormatException,
        );
        expect(await cache.list().toList(), isEmpty);
      }
      var checks = 0;
      await expectLater(
        ReceivedFiles.receive(
          cache,
          manifest,
          (_, write) async {
            await write([0, 0]);
          },
          check: () {
            if (++checks > 1) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(await cache.list().toList(), isEmpty);
    },
  );

  test(
    'ZIP packaging preserves folders and bytes without extracting',
    () async {
      final folder = await Directory('${workspace.path}/Folder').create();
      await Directory('${folder.path}/empty').create();
      await File('${folder.path}/data').writeAsBytes([0, 7, 255]);
      final cache = await Directory('${workspace.path}/cache').create();
      await expectLater(
        packageFiles(
          [folder.path],
          cache,
          inspect: (_) async {},
          check: () {},
          reserveSpace: (_) async => throw StateError('disk full'),
        ),
        throwsStateError,
      );
      expect(await cache.list().toList(), isEmpty);
      final zip = await packageFiles(
        [folder.path],
        cache,
        inspect: (_) async {},
        check: () {},
      );
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      expect(archive.files.any((e) => e.name == 'Folder/empty/'), true);
      expect(
        archive.files.singleWhere((e) => e.name == 'Folder/data').content,
        [0, 7, 255],
      );
      await expectLater(
        packageFiles(
          [folder.path, folder.path],
          cache,
          inspect: (_) async {},
          check: () {},
        ),
        throwsFormatException,
      );
    },
  );

  test('symbolic link roots are rejected', () async {
    final file = await File('${workspace.path}/original')
        .writeAsString('secret');
    final link = Link('${workspace.path}/link');
    try {
      await link.create(file.path);
    } on FileSystemException {
      return;
    }
    await expectLater(FileContent.create([link.path]), throwsFormatException);
  });

  test(
    'cache capacity includes retained files and the free-space reserve',
    () async {
      const gib = 1024 * 1024 * 1024;
      final cache = await Directory('${workspace.path}/cache').create();
      await File('${cache.path}/retained').writeAsBytes(List.filled(8, 0));
      await expectLater(
        checkFileCacheSpace(
          cache,
          incomingBytes: 3,
          cacheLimit: 10,
          availableBytes: gib + 3,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('cache is full'),
          ),
        ),
      );
      await expectLater(
        checkFileCacheSpace(
          cache,
          incomingBytes: 2,
          cacheLimit: 10,
          availableBytes: gib + 1,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('disk space'),
          ),
        ),
      );
      await checkFileCacheSpace(
        cache,
        incomingBytes: 2,
        cacheLimit: 10,
        availableBytes: gib + 2,
      );
    },
  );
}
