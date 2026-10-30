import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:archive/archive_io.dart';

import 'content.dart';

/// Explicit ZIP packaging runs off the UI isolate and never extracts archives.
Future<File> packageFiles(
  List<String> roots,
  Directory cache, {
  required Future<void> Function(String) inspect,
  required void Function() check,
  Future<void> Function(int)? reserveSpace,
  int limit = defaultItemBytes,
}) async {
  final entries =
      <({String local, String name, bool directory, int size, int modified})>[];
  final names = <String>{};
  var total = 0;
  Future<void> walk(String path, String name) async {
    check();
    validateRelativePath(name);
    await inspect(path);
    if (!names.add(name.toLowerCase()) || entries.length >= 100000) {
      throw const FormatException(
        'Duplicate name or too many archive entries.',
      );
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('Links cannot be packaged.');
    }
    final stat = await FileStat.stat(path);
    final directory = type == FileSystemEntityType.directory;
    total += directory ? 0 : stat.size;
    if (total > limit) {
      throw const FormatException('Files exceed the item limit.');
    }
    entries.add((
      local: path,
      name: name,
      directory: directory,
      size: stat.size,
      modified: stat.modified.microsecondsSinceEpoch,
    ));
    if (directory) {
      await for (final child in Directory(path).list(followLinks: false)) {
        await walk(
          child.path,
          '$name/${child.uri.pathSegments.where((s) => s.isNotEmpty).last}',
        );
      }
    }
  }

  for (final root in roots) {
    await walk(
      root,
      File(root).uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
  }
  // Store-only ZIPs need the input bytes plus bounded headers and filenames.
  final estimatedBytes = entries.fold<int>(
    total + 65536,
    (bytes, entry) => bytes + 256 + 2 * utf8.encode(entry.name).length,
  );
  await reserveSpace?.call(estimatedBytes);
  check();
  final temporary = await cache.createTemp('outgoing-');
  final output = '${temporary.path}${Platform.pathSeparator}Shared files.zip';
  try {
    await Isolate.run(() async {
      final zip = ZipFileEncoder()..create(output, level: 0);
      try {
        for (final entry in entries) {
          final type = await FileSystemEntity.type(
            entry.local,
            followLinks: false,
          );
          final stat = await FileStat.stat(entry.local);
          if (type !=
                  (entry.directory
                      ? FileSystemEntityType.directory
                      : FileSystemEntityType.file) ||
              stat.size != entry.size ||
              stat.modified.microsecondsSinceEpoch != entry.modified) {
            throw const FormatException('A source changed while packaging.');
          }
          if (entry.directory) {
            zip.addArchiveFile(ArchiveFile.directory(entry.name));
          } else {
            await zip.addFile(File(entry.local), entry.name, 0);
            final after = await FileStat.stat(entry.local);
            if (after.size != entry.size || after.modified != stat.modified) {
              throw const FormatException('A source changed while packaging.');
            }
          }
        }
      } finally {
        await zip.close();
      }
    });
    check();
    final file = File(output);
    if (await file.length() > limit) {
      throw const FormatException('ZIP exceeds the item limit.');
    }
    return file;
  } catch (_) {
    await temporary.delete(recursive: true);
    rethrow;
  }
}
