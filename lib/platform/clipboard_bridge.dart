import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/protocol.dart';

class ClipboardSnapshot {
  ClipboardSnapshot(
    this.text,
    this.revision, {
    this.ownWrite = false,
    this.sensitive = false,
  });
  final String? text;
  final int revision;
  final bool ownWrite;

  /// The source app marked this copy private, e.g. a password manager.
  final bool sensitive;
}

class ClipboardBridge {
  static const channel = MethodChannel('dev.localclipboard/native');
  final changes = StreamController<void>.broadcast();
  final actions = StreamController<String>.broadcast();
  bool get supportsAutomatic => Platform.isWindows || Platform.isAndroid;

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
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
      );
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    return ClipboardSnapshot(text, 0);
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
