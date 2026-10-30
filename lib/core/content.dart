import 'dart:convert';

import 'protocol.dart';

const cachedItemBytes = 16 * 1024 * 1024;
const defaultItemBytes = 4 * 1024 * 1024 * 1024;
const fileLifetime = Duration(minutes: 15);
const contentFeature = 'content1';

int boundedInt(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid content size or index.');
  }
  return value;
}

/// Immutable, canonical metadata. No sender-controlled filesystem paths escape
/// this validation boundary. Receivers must additionally confine disk writes.
class FileEntry {
  const FileEntry(
    this.index,
    this.path, {
    this.directory = false,
    this.size = 0,
    this.mtime,
  });
  final int index;
  final String path;
  final bool directory;
  final int size;
  final int? mtime;
  Map<String, dynamic> toJson() => {
    'i': index,
    'path': path,
    if (directory) 'dir': true,
    if (!directory) 'size': size,
    if (mtime != null) 'mtime': mtime,
  };
}

class FileManifest {
  FileManifest._(this.entries, this.roots, this.totalBytes);
  final List<FileEntry> entries;
  final List<String> roots;
  final int totalBytes;
  int get fileCount => entries.where((e) => !e.directory).length;

  factory FileManifest.fromJson(
    Map<String, dynamic> data, {
    int limit = defaultItemBytes,
  }) {
    if (utf8.encode(jsonEncode(data)).length > 400 * 1024) {
      throw const FormatException('Manifest is too large.');
    }
    final raw = data['entries'];
    final rawRoots = data['roots'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 5000 ||
        rawRoots is! List ||
        rawRoots.isEmpty) {
      throw const FormatException('Invalid manifest.');
    }
    final entries = <FileEntry>[];
    final paths = <String, FileEntry>{};
    var total = 0;
    for (final value in raw) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid entry.');
      }
      final path = field(value, 'path', max: 1024);
      validateRelativePath(path);
      final key = path.toLowerCase();
      if (paths.containsKey(key)) {
        throw const FormatException('Duplicate path.');
      }
      if (value['dir'] != null && value['dir'] is! bool) {
        throw const FormatException('Invalid directory.');
      }
      final directory = value['dir'] == true;
      if (directory && value['size'] != null && value['size'] != 0) {
        throw const FormatException('Directories cannot contain file bytes.');
      }
      final entry = FileEntry(
        boundedInt(value['i'], entries.length, entries.length),
        path,
        directory: directory,
        size: directory ? 0 : boundedInt(value['size'], 0, limit),
        mtime: value['mtime'] == null
            ? null
            : boundedInt(value['mtime'], 0, 8640000000000),
      );
      total += entry.size;
      if (total > limit) throw const FormatException('Item is too large.');
      paths[key] = entry;
      entries.add(entry);
    }
    for (final entry in entries) {
      var parent = entry.path;
      while (parent.contains('/')) {
        parent = parent.substring(0, parent.lastIndexOf('/'));
        if (paths[parent.toLowerCase()]?.directory != true) {
          throw const FormatException('Missing parent directory.');
        }
      }
    }
    final roots =
        entries.where((e) => !e.path.contains('/')).map((e) => e.path).toList()
          ..sort();
    if (rawRoots.any((r) => r is! String) ||
        rawRoots.toSet().length != rawRoots.length ||
        rawRoots.length != roots.length ||
        !roots.every(rawRoots.contains) ||
        boundedInt(data['totalBytes'], 0, limit) != total ||
        boundedInt(data['fileCount'], 0, 5000) !=
            entries.where((e) => !e.directory).length) {
      throw const FormatException('Manifest totals or roots do not match.');
    }
    return FileManifest._(
      List.unmodifiable(entries),
      List.unmodifiable(roots),
      total,
    );
  }

  Map<String, dynamic> toJson() => {
    'totalBytes': totalBytes,
    'fileCount': fileCount,
    'roots': roots,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

void validateRelativePath(String path) {
  if (path.length > 1024 ||
      utf8.encode(path).length > 4096 ||
      RegExp(r'[\\:\x00-\x1f\x7f]').hasMatch(path)) {
    throw const FormatException('Unsafe path.');
  }
  final parts = path.split('/');
  if (parts.length > 32) throw const FormatException('Path is too deep.');
  for (final part in parts) {
    // Reject combining marks conservatively: Dart core has no NFC normalizer.
    // This prevents NFC/NFD aliases without introducing a dependency.
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith(' ') ||
        part.endsWith('.') ||
        RegExp(r'[<>"|?*\u0300-\u036f]').hasMatch(part) ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw const FormatException('Unsafe path segment.');
    }
  }
}

class ImageMeta {
  ImageMeta._(this.width, this.height, this.size, this.name, this.hash);
  final int width, height, size;
  final String name;
  final String? hash;
  factory ImageMeta.fromJson(Map<String, dynamic> data) {
    final width = boundedInt(data['width'], 1, 16384);
    final height = boundedInt(data['height'], 1, 16384);
    if (data['mime'] != 'image/png' || width * height > 50000000) {
      throw const FormatException('Unsupported image.');
    }
    final name = data['name'] == null
        ? 'Screenshot.png'
        : field(data, 'name', max: 255);
    validateRelativePath(name);
    if (name.contains('/')) throw const FormatException('Invalid image name.');
    final hash = data['sha256'];
    if (hash != null &&
        (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash))) {
      throw const FormatException('Invalid image hash.');
    }
    return ImageMeta._(
      width,
      height,
      boundedInt(data['size'], 1, cachedItemBytes),
      name,
      hash as String?,
    );
  }
  Map<String, dynamic> toJson() => {
    'mime': 'image/png',
    'width': width,
    'height': height,
    'size': size,
    'name': name,
    if (hash != null) 'sha256': hash,
  };
}

class ClipPayload {
  ClipPayload._(this.kind, this.text, this.image, this.files);
  final String kind;
  final String? text;
  final ImageMeta? image;
  final FileManifest? files;
  bool get isText => kind == 'text';
  int get totalBytes => files?.totalBytes ?? image?.size ?? 0;
  bool get cached => !isText && totalBytes <= cachedItemBytes;
  Map<int, int> get streams => {
    if (image != null) 0: image!.size,
    if (files != null)
      for (final e in files!.entries)
        if (!e.directory) e.index: e.size,
  };
  factory ClipPayload.fromJson(
    Map<String, dynamic> data, {
    int limit = defaultItemBytes,
  }) {
    final kind = data['kind'] ?? 'text';
    if (kind == 'text') {
      return ClipPayload._('text', validText(data['text']), null, null);
    }
    if (kind == 'files') {
      return ClipPayload._(
        'files',
        null,
        null,
        FileManifest.fromJson(data, limit: limit),
      );
    }
    if (kind == 'image' || kind == 'mixed') {
      final meta = kind == 'mixed' ? data['image'] : data;
      if (meta is! Map<String, dynamic>) {
        throw const FormatException('Invalid image metadata.');
      }
      return ClipPayload._(
        kind as String,
        kind == 'mixed' ? validText(data['text']) : null,
        ImageMeta.fromJson(meta),
        null,
      );
    }
    throw const FormatException('Unsupported content kind.');
  }
  Map<String, dynamic> toJson() => {
    if (!isText) 'kind': kind,
    if (text != null) 'text': text,
    if (kind == 'image') ...image!.toJson(),
    if (kind == 'mixed') 'image': image!.toJson(),
    if (files != null) ...files!.toJson(),
    if (!isText) 'tier': cached ? 'cached' : 'relayed',
  };
}
