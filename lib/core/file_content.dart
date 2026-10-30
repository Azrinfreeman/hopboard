import 'dart:io';

import 'content.dart';
import 'protocol.dart';

/// Local paths stay on the sender; only validated relative names go on the wire.
class FileContent {
  FileContent._(this.payload, this.paths, this.stamps);
  final ClipPayload payload;
  final Map<int, String> paths;
  final Map<int, FileStat> stamps;

  static Future<FileContent> create(
    List<String> roots, {
    Future<void> Function(String)? inspect,
    int limit = defaultItemBytes,
  }) async {
    final entries = <FileEntry>[];
    final paths = <int, String>{};
    final stamps = <int, FileStat>{};
    var total = 0;
    Future<void> walk(String local, String relative) async {
      validateRelativePath(relative);
      if (entries.length >= 5000) {
        throw const FormatException('At most 5000 entries can be shared.');
      }
      await inspect?.call(local);
      final type = await FileSystemEntity.type(local, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw const FormatException(
          'Links and unavailable files cannot be shared.',
        );
      }
      final stat = await FileStat.stat(local);
      final index = entries.length;
      final directory = type == FileSystemEntityType.directory;
      total += directory ? 0 : stat.size;
      if (total > limit) {
        throw const FormatException('Files exceed your item size limit.');
      }
      entries.add(
        FileEntry(
          index,
          relative,
          directory: directory,
          size: directory ? 0 : stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
        ),
      );
      if (directory) {
        await for (final child in Directory(local).list(followLinks: false)) {
          await walk(
            child.path,
            '$relative/${child.uri.pathSegments.where((s) => s.isNotEmpty).last}',
          );
        }
      } else {
        paths[index] = local;
        stamps[index] = stat;
      }
    }

    for (final root in roots) {
      final name = File(root).uri.pathSegments.where((s) => s.isNotEmpty).last;
      await walk(root, name);
    }
    final payload = ClipPayload.fromJson({
      'kind': 'files',
      'entries': entries.map((e) => e.toJson()).toList(),
      'roots': entries
          .where((e) => !e.path.contains('/'))
          .map((e) => e.path)
          .toList(),
      'totalBytes': total,
      'fileCount': paths.length,
    });
    return FileContent._(payload, paths, stamps);
  }

  Stream<List<int>> open(
    int entry,
    int offset, {
    Future<void> Function(String)? inspect,
  }) async* {
    final path = paths[entry];
    final stamp = stamps[entry];
    if (path == null || stamp == null || offset < 0 || offset > stamp.size) {
      throw const FormatException('Invalid file entry.');
    }
    Future<void> check() async {
      await inspect?.call(path);
      final stat = await FileStat.stat(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          stat.size != stamp.size ||
          stat.modified != stamp.modified) {
        throw SessionException('A copied file changed. Copy it again.');
      }
    }

    await check();
    yield* File(path).openRead(offset, stamp.size);
    await check();
  }
}

typedef FileFetch = Future<void> Function(
  int entry,
  Future<void> Function(List<int>) write,
);

/// Account for retained items and partial transfers before starting disk work.
Future<void> checkFileCacheSpace(
  Directory cache, {
  required int incomingBytes,
  required int cacheLimit,
  required int availableBytes,
}) async {
  const reserve = 1024 * 1024 * 1024;
  if (incomingBytes > availableBytes - reserve) {
    throw SessionException('Not enough disk space. Keep at least 1 GiB free.');
  }
  var used = 0;
  await for (final entry in cache.list(recursive: true, followLinks: false)) {
    if (entry is File) used += await entry.length();
    if (used + incomingBytes > cacheLimit) {
      throw SessionException(
        'Receive cache is full. Clear received files first.',
      );
    }
  }
  if (incomingBytes > cacheLimit) {
    throw SessionException('Files exceed the receive cache limit.');
  }
}

/// Each transfer owns a new directory; failures never expose partial roots.
class ReceivedFiles {
  ReceivedFiles(this.directory, this.roots);
  final Directory directory;
  final List<String> roots;

  static Future<ReceivedFiles> receive(
    Directory cache,
    FileManifest manifest,
    FileFetch fetch, {
    required void Function() check,
    Future<void> Function(String)? markDownloaded,
    void Function(int)? progress,
  }) async {
    // Revalidate callers too, before creating anything on disk.
    manifest = FileManifest.fromJson(manifest.toJson());
    await cache.create(recursive: true);
    if (await FileSystemEntity.type(cache.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Directory(await cache.resolveSymbolicLinks()).absolute.uri
                .toString()
                .toLowerCase() !=
            cache.absolute.uri.toString().toLowerCase()) {
      throw const FileSystemException('Receive cache must not contain links.');
    }
    final dir = await cache.createTemp('item-');
    final staging = await cache.createTemp('partial-');
    var received = 0;
    try {
      for (final entry in manifest.entries) {
        check();
        final destination =
            '${dir.path}${Platform.pathSeparator}${entry.path.replaceAll('/', Platform.pathSeparator)}';
        if (entry.directory) {
          await Directory(destination).create(recursive: true);
          continue;
        }
        final file = File(
          '${staging.path}${Platform.pathSeparator}${entry.index}',
        );
        await File(destination).parent.create(recursive: true);
        final parent = Directory(
          await File(destination).parent.resolveSymbolicLinks(),
        ).absolute.uri.toString().toLowerCase();
        if (!parent.startsWith(dir.absolute.uri.toString().toLowerCase())) {
          throw const FileSystemException('Unsafe receive path.');
        }
        final output = await file.open(mode: FileMode.writeOnly);
        var length = 0;
        try {
          await fetch(entry.index, (chunk) async {
            check();
            length += chunk.length;
            if (length > entry.size) {
              throw const FormatException('File is too long.');
            }
            await output.writeFrom(chunk);
            received += chunk.length;
            progress?.call(
              manifest.totalBytes == 0
                  ? 100
                  : received * 100 ~/ manifest.totalBytes,
            );
          });
          if (length != entry.size) {
            throw const FormatException('File is incomplete.');
          }
          await output.flush();
        } finally {
          await output.close();
        }
        await file.rename(destination);
        final completed = File(destination);
        await markDownloaded?.call(destination);
        if (entry.mtime != null) {
          await completed.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(entry.mtime!),
          );
        }
      }
      check();
      await staging.delete(recursive: true);
      return ReceivedFiles(
        dir,
        manifest.roots
            .map((r) => '${dir.path}${Platform.pathSeparator}$r')
            .toList(),
      );
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> delete() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
