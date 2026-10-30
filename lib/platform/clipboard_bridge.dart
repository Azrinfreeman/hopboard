import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/image_content.dart';

class ClipboardSnapshot {
  ClipboardSnapshot(
    this.text,
    this.revision, {
    this.ownWrite = false,
    this.sensitive = false,
    this.png,
    this.hasImage = false,
    this.hasFiles = false,
    this.filePaths = const [],
    this.cut = false,
  });
  final List<String> filePaths;
  final bool cut;
  final String? text;
  final int revision;
  final bool ownWrite;
  final Uint8List? png;
  final bool hasImage, hasFiles;
  bool get hasContent => text?.isNotEmpty == true || hasImage || hasFiles;

  /// The source app marked this copy private, e.g. a password manager.
  final bool sensitive;
}

class ClipboardBridge {
  static const channel = MethodChannel('dev.localclipboard/native');
  final changes = StreamController<void>.broadcast();
  final fileDrops = StreamController<List<String>>.broadcast();
  final actions = StreamController<String>.broadcast();
  bool get supportsAutomatic => Platform.isWindows || Platform.isAndroid;
  bool get supportsImages => Platform.isWindows;
  bool get supportsFiles => Platform.isWindows;

  Future<List<String>> pickFiles({bool folder = false}) async =>
      (await channel.invokeListMethod<String>(
        folder ? 'pickFolder' : 'pickFiles',
      )) ??
      [];

  Future<void> showReceivedFolder(String path) =>
      channel.invokeMethod<void>('showReceivedFolder', {'path': path});

  Future<void> inspectFile(String path) =>
      channel.invokeMethod<void>('inspectFile', {'path': path});

  Future<Directory> receiveCache() async =>
      Directory((await channel.invokeMethod<String>('receiveCache'))!);

  Future<int> availableFileSpace(String path) async =>
      (await channel.invokeMethod<int>('availableFileSpace', {'path': path}))!;

  Future<bool> writeFiles(List<String> paths, {int? expectedRevision}) async =>
      await channel.invokeMethod<bool>('writeFiles', {
        'paths': paths,
        'expectedRevision': expectedRevision,
      }) ??
      false;

  Future<void> cancelImageWrite() async {
    if (supportsImages) await channel.invokeMethod<void>('cancelImageWrite');
  }

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'droppedFiles':
          fileDrops.add((call.arguments as List).cast<String>());
        case 'clipboardChanged':
          changes.add(null);
        case 'trayAction':
          actions.add(call.arguments as String);
        case 'pasted':
          actions.add('pasted:${call.arguments as String}');
        case 'networkChanged':
          actions.add('networkChanged');
      }
    });
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) {
      await channel.invokeMethod<void>('initialize');
    }
  }

  Future<ClipboardSnapshot> read() async {
    if (Platform.isWindows || Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'readClipboard',
      );
      return ClipboardSnapshot(
        result?['text'] as String?,
        result?['revision'] as int? ?? 0,
        ownWrite: result?['ownWrite'] == true,
        sensitive: result?['sensitive'] == true,
        hasImage: result?['hasImage'] == true,
        hasFiles: result?['hasFiles'] == true,
      );
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    return ClipboardSnapshot(text, 0);
  }

  Future<ClipboardSnapshot> readContent({bool includeImages = true}) async {
    if (!supportsImages) return read();
    final result = await channel.invokeMapMethod<String, dynamic>(
      'readClipboard',
      {'includeImage': includeImages, 'includeFiles': true},
    );
    if (result == null) throw const FormatException('Clipboard unavailable.');
    Uint8List? png;
    final token = result['imageToken'] as String?;
    if (token != null) {
      final size = result['imageSize'] as int;
      if (size < 33 || size > 16 * 1024 * 1024) {
        throw const FormatException('Image exceeds 16 MiB.');
      }
      png = Uint8List(size);
      try {
        var offset = 0;
        while (offset < size) {
          final chunk = await channel.invokeMethod<Uint8List>(
            'readImageChunk',
            {'token': token, 'offset': offset},
          );
          if (chunk == null ||
              chunk.isEmpty ||
              chunk.length > 65536 ||
              offset + chunk.length > size) {
            throw const FormatException('Incomplete clipboard image.');
          }
          png.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        pngMetadata(png);
      } finally {
        await channel.invokeMethod<void>('releaseImageRead', {'token': token});
      }
    }
    return ClipboardSnapshot(
      result['text'] as String?,
      result['revision'] as int,
      ownWrite: result['ownWrite'] == true,
      sensitive: result['sensitive'] == true,
      hasImage: result['hasImage'] == true,
      hasFiles: result['hasFiles'] == true,
      png: png,
      filePaths: (result['filePaths'] as List?)?.cast<String>() ?? const [],
      cut: result['cut'] == true,
    );
  }

  Future<bool> writeImage(
    Uint8List png, {
    String? text,
    int? expectedRevision,
  }) async {
    if (!supportsImages) {
      throw SessionException('Image clipboard is unavailable on this device.');
    }
    pngMetadata(png);
    final token = await channel.invokeMethod<String>('beginImageWrite', {
      'size': png.length,
    });
    for (var offset = 0; offset < png.length; offset += 65536) {
      await channel.invokeMethod<void>('appendImageWrite', {
        'token': token,
        'bytes': Uint8List.sublistView(
          png,
          offset,
          (offset + 65536).clamp(0, png.length),
        ),
      });
    }
    return await channel.invokeMethod<bool>('finishImageWrite', {
          'token': token,
          'text': ?text,
          'expectedRevision': expectedRevision,
        }) ??
        false;
  }

  Future<bool> write(String text, {int? expectedRevision}) async {
    if (Platform.isWindows || Platform.isAndroid) {
      return await channel.invokeMethod<bool>('writeClipboard', {
            'text': text,
            'expectedRevision': expectedRevision,
          }) ??
          false;
    }
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  }

  Future<void> keepAwake(bool enabled) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await channel.invokeMethod<void>('keepAwake', enabled);
    }
  }

  Future<void> updateTray(bool paused, String status) async {
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('updateTray', {
        'paused': paused,
        'status': status,
      });
    }
  }

  /// A tray notice on Windows when the window is not in front. Never pass
  /// clipboard content: notices can appear on a locked or shared screen.
  Future<void> notify(String title, String body) async {
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('notify', {
        'title': title,
        'body': body,
      });
    }
  }

  Future<void> quit() => channel.invokeMethod<void>('quit');

  Future<void> ensureNetworkAccess() async {
    if (Platform.isAndroid) {
      final allowed = await channel.invokeMethod<bool>('requestNetwork');
      if (allowed != true) {
        throw SessionException(
          'Local-network permission is required. Enable Nearby devices access in Settings.',
        );
      }
    }
  }
}
