import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/content.dart';
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
    this.changeStamp,
    this.html,
    this.rtf,
  });
  final List<String> filePaths;

  /// Formatted copies of [text] (Windows "HTML Format" and RTF), if any.
  final String? html, rtf;
  final bool cut;

  /// Android clipboard change time captured with an explicit focused read.
  final int? changeStamp;
  final String? text;
  final int revision;
  final bool ownWrite;
  final Uint8List? png;
  final bool hasImage, hasFiles;
  bool get hasContent => text?.isNotEmpty == true || hasImage || hasFiles;

  /// The source app marked this copy private, e.g. a password manager.
  final bool sensitive;
}

/// Result of a clipboard write made while the app is not in front.
class BackgroundWrite {
  const BackgroundWrite(this.revision, this.stamp);
  final int revision;

  /// The clipboard's change time after the write, or null if Android hides it.
  final int? stamp;
}

class ClipboardBridge {
  static const channel = MethodChannel('dev.localclipboard/native');
  final changes = StreamController<void>.broadcast();
  final fileDrops = StreamController<List<String>>.broadcast();
  final actions = StreamController<String>.broadcast();

  /// Item ids whose virtual files an app started pasting.
  final virtualRequests = StreamController<String>.broadcast();

  /// Android's explicit Share / notification requests. Returns after host ACK.
  Future<void> Function(ClipboardSnapshot snapshot, bool sharedText)?
  onSendText;

  Future<void> readyForSendRequests() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('sendReady');
  }

  bool get supportsAutomatic => Platform.isWindows || Platform.isAndroid;
  bool get supportsBackgroundReceive => Platform.isAndroid;

  /// The clipboard's last-change time, never its contents. Null if unreadable.
  Future<int?> clipboardStamp() async {
    if (!Platform.isAndroid) return null;
    try {
      return await channel.invokeMethod<int>('clipboardStamp');
    } on PlatformException {
      return null;
    }
  }

  /// Writes received text without window focus (Android foreground service).
  Future<BackgroundWrite> writeInBackground(String text) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'writeClipboardBackground',
      {'text': text},
    );
    return BackgroundWrite(
      (result?['revision'] as num?)?.toInt() ?? 0,
      (result?['stamp'] as num?)?.toInt(),
    );
  }

  /// Starts or stops the Android service that keeps this phone connected.
  Future<void> setBackgroundService(
    bool enabled, {
    String? hostName,
    bool paused = false,
  }) async {
    if (!Platform.isAndroid) return;
    await channel.invokeMethod<void>('backgroundService', {
      'enabled': enabled,
      'host': hostName,
      'paused': paused,
    });
  }

  /// A quiet notice that text arrived. Never contains the text itself.
  Future<void> notifyReceived(String sender, {bool needsAction = false}) async {
    if (!Platform.isAndroid) return;
    await channel.invokeMethod<void>('notifyReceived', {
      'sender': sender,
      'needsAction': needsAction,
    });
  }

  /// Asks Android to add the Send to PC Quick Settings tile. Returns 2 when it
  /// was added, 1 when it was already there, 0 when declined and -1 when this
  /// Android version cannot offer it (use the Quick Settings edit screen).
  Future<int> requestSendTile() async {
    if (!Platform.isAndroid) return -1;
    return await channel.invokeMethod<int>('requestSendTile') ?? -1;
  }

  bool get supportsImages => Platform.isWindows;
  bool get supportsFiles => Platform.isWindows;

  /// Received files can be placed on the clipboard before they download and
  /// stream while an app such as Explorer pastes them.
  bool get supportsVirtualFiles => Platform.isWindows;

  /// Places [manifest] on the clipboard as virtual files for item [id].
  /// Returns false when the clipboard changed since [expectedRevision].
  Future<bool> writeVirtualFiles(
    String id,
    FileManifest manifest, {
    int? expectedRevision,
  }) async =>
      await channel.invokeMethod<bool>('writeVirtualFiles', {
        'id': id,
        'entries': [
          for (final entry in manifest.entries)
            {
              'path': entry.path,
              'directory': entry.directory,
              'size': entry.size,
              'mtime': ?entry.mtime,
            },
        ],
        'expectedRevision': expectedRevision,
      }) ??
      false;

  /// Reports download state of manifest entry [entry] (its list position).
  Future<void> virtualFileProgress(
    String id, {
    int entry = -1,
    String? path,
    int available = 0,
    bool done = false,
    bool failed = false,
  }) => channel.invokeMethod<bool>('virtualFileProgress', {
    'id': id,
    'entry': entry,
    'path': ?path,
    'available': available,
    'done': done,
    'failed': failed,
  });

  /// Empties the clipboard if it still holds virtual files for [id].
  Future<bool> clearVirtualFiles(String id) async =>
      await channel.invokeMethod<bool>('clearVirtualFiles', {'id': id}) ??
      false;

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

  Future<bool> writeFiles(
    List<String> paths, {
    int? expectedRevision,
    String? replaceVirtual,
  }) async =>
      await channel.invokeMethod<bool>('writeFiles', {
        'paths': paths,
        'expectedRevision': expectedRevision,
        'replaceVirtual': ?replaceVirtual,
      }) ??
      false;

  Future<void> cancelImageWrite() async {
    if (supportsImages) await channel.invokeMethod<void>('cancelImageWrite');
  }

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'sendExternalText':
          final request = Map<String, dynamic>.from(call.arguments as Map);
          final handler = onSendText;
          if (handler == null) {
            throw PlatformException(
              code: 'starting',
              message: 'Open Hopboard and try again.',
            );
          }
          try {
            await handler(
              ClipboardSnapshot(
                request['text'] as String?,
                (request['revision'] as num?)?.toInt() ?? 0,
                ownWrite: request['ownWrite'] == true,
                sensitive: request['sensitive'] == true,
                changeStamp: (request['stamp'] as num?)?.toInt(),
              ),
              request['sharedText'] == true,
            );
          } catch (failure) {
            throw PlatformException(code: 'send', message: failure.toString());
          }
          return null;
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
        case 'virtualFilesRequested':
          virtualRequests.add(call.arguments as String);
      }
    });
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) {
      await channel.invokeMethod<void>('initialize');
    }
  }

  /// [includeRich] also reads HTML and RTF. Only a capture of a new copy
  /// asks: other apps render those formats on demand, which can be slow.
  Future<ClipboardSnapshot> read({bool includeRich = false}) async {
    if (Platform.isWindows || Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'readClipboard',
        Platform.isWindows && includeRich ? {'includeRich': true} : null,
      );
      return ClipboardSnapshot(
        result?['text'] as String?,
        result?['revision'] as int? ?? 0,
        ownWrite: result?['ownWrite'] == true,
        sensitive: result?['sensitive'] == true,
        hasImage: result?['hasImage'] == true,
        hasFiles: result?['hasFiles'] == true,
        html: result?['html'] as String?,
        rtf: result?['rtf'] as String?,
      );
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    return ClipboardSnapshot(text, 0);
  }

  Future<ClipboardSnapshot> readContent({
    bool includeImages = true,
    bool includeRich = false,
  }) async {
    if (!supportsImages) return read(includeRich: includeRich);
    final result = await channel.invokeMapMethod<String, dynamic>(
      'readClipboard',
      {
        'includeImage': includeImages,
        'includeFiles': true,
        'includeRich': includeRich,
      },
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
      html: result['html'] as String?,
      rtf: result['rtf'] as String?,
    );
  }

  Future<bool> writeImage(
    Uint8List png, {
    String? text,
    int? expectedRevision,
    String? html,
    String? rtf,
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
          'html': ?html,
          'rtf': ?rtf,
          'expectedRevision': expectedRevision,
        }) ??
        false;
  }

  Future<bool> write(
    String text, {
    int? expectedRevision,
    String? html,
    String? rtf,
  }) async {
    if (Platform.isWindows || Platform.isAndroid) {
      return await channel.invokeMethod<bool>('writeClipboard', {
            'text': text,
            'html': ?html,
            'rtf': ?rtf,
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
