import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';
import 'package:local_clipboard/platform/discovery.dart';

class FakeClipboard extends ClipboardBridge {
  String? text;
  String? html, rtf;
  Uint8List? png;
  int revision = 0;
  bool own = false;
  bool sensitive = false;
  int writes = 0;
  bool unmarkedChangeAfterWrite = false;
  final notices = <String>[];
  void Function()? beforeWrite;
  DateTime? readBusyUntil;
  Duration? busyAfterWrite;
  int readAttempts = 0;
  int writeAttempts = 0;
  int busyWrites = 0;
  Object? readFailure;
  Completer<void>? readGate;

  Future<void> _checkRead() async {
    readAttempts++;
    await readGate?.future;
    if (readFailure != null) throw readFailure!;
    if (readBusyUntil?.isAfter(DateTime.now()) == true) {
      throw PlatformException(code: 'busy', message: 'Clipboard busy.');
    }
  }

  // Phone background receive.
  @override
  bool get supportsBackgroundReceive => true;
  int stampValue = 1;
  bool stampReadable = true;
  bool backgroundWriteDenied = false;
  int backgroundWrites = 0;
  final serviceStates = <bool>[];
  final receivedNotices = <String>[];

  @override
  Future<int?> clipboardStamp() async => stampReadable ? stampValue : null;

  @override
  Future<BackgroundWrite> writeInBackground(String value) async {
    if (backgroundWriteDenied) {
      throw PlatformException(code: 'denied', message: 'Blocked.');
    }
    text = value;
    filePaths = [];
    png = null;
    revision++;
    own = true;
    sensitive = false;
    stampValue++;
    writes++;
    backgroundWrites++;
    return BackgroundWrite(revision, stampReadable ? stampValue : null);
  }

  @override
  Future<void> setBackgroundService(
    bool enabled, {
    String? hostName,
    bool paused = false,
  }) async => serviceStates.add(enabled);

  @override
  Future<void> notifyReceived(String sender, {bool needsAction = false}) async {
    receivedNotices.add(needsAction ? 'action:$sender' : sender);
  }

  @override
  bool get supportsAutomatic => true;
  @override
  bool get supportsImages => true;
  @override
  bool get supportsFiles => filesEnabled;
  bool filesEnabled = false;
  List<String> filePaths = [];
  bool cut = false;
  Directory? fileCache;
  Completer<void>? receiveGate;
  int availableBytes = 100 * 1024 * 1024 * 1024;
  @override
  Future<int> availableFileSpace(String path) async => availableBytes;
  @override
  Future<void> inspectFile(String path) async {}
  @override
  Future<Directory> receiveCache() async {
    await receiveGate?.future;
    return fileCache ??= await Directory.systemTemp.createTemp(
      'hopboard-test-',
    );
  }

  @override
  Future<bool> writeFiles(
    List<String> paths, {
    int? expectedRevision,
    String? replaceVirtual,
  }) async {
    final upgrade = replaceVirtual != null && replaceVirtual == virtualId;
    final success = await write(
      '',
      expectedRevision: upgrade ? revision : expectedRevision,
    );
    if (success) {
      filePaths = paths;
      text = null;
    }
    return success;
  }

  bool virtualEnabled = false;
  @override
  bool get supportsVirtualFiles => virtualEnabled;

  /// Id of the item whose virtual files are on this clipboard, if any.
  String? virtualId;
  List<String> virtualPaths = [];
  final progress = <String, Map<int, ({String? path, int bytes, bool done})>>{};
  final failedVirtual = <String>{};

  @override
  Future<bool> writeVirtualFiles(
    String id,
    FileManifest manifest, {
    int? expectedRevision,
  }) async {
    final success = await write('', expectedRevision: expectedRevision);
    if (success) {
      text = null;
      virtualId = id;
      virtualPaths = [for (final entry in manifest.entries) entry.path];
    }
    return success;
  }

  @override
  Future<void> virtualFileProgress(
    String id, {
    int entry = -1,
    String? path,
    int available = 0,
    bool done = false,
    bool failed = false,
  }) async {
    if (failed) {
      failedVirtual.add(id);
      return;
    }
    final entries = progress.putIfAbsent(id, () => {});
    final previous = entries[entry];
    entries[entry] = (
      path: path ?? previous?.path,
      bytes: available,
      done: done || (previous?.done ?? false),
    );
  }

  @override
  Future<bool> clearVirtualFiles(String id) async {
    if (virtualId != id) return false;
    virtualId = null;
    virtualPaths = [];
    revision++;
    own = false;
    changes.add(null);
    return true;
  }

  /// Simulates Explorer starting to paste the virtual files.
  void pasteVirtual() => virtualRequests.add(virtualId!);

  void userCopyFiles(
    List<String> paths, {
    bool private = false,
    bool move = false,
  }) {
    filePaths = paths;
    png = null;
    text = null;
    cut = move;
    sensitive = private;
    own = false;
    revision++;
    changes.add(null);
  }

  @override
  Future<void> cancelImageWrite() async {}
  @override
  Future<void> initialize() async {}
  @override
  Future<void> ensureNetworkAccess() async {}
  @override
  Future<void> keepAwake(bool enabled) async {}
  @override
  Future<void> updateTray(bool paused, String status) async {}
  @override
  Future<void> notify(String title, String body) async {
    notices.add(body);
  }

  @override
  Future<ClipboardSnapshot> read({bool includeRich = false}) async {
    await _checkRead();
    return ClipboardSnapshot(
      text,
      revision,
      html: html,
      rtf: rtf,
      ownWrite: own,
      sensitive: sensitive,
      hasImage: png != null,
      hasFiles: filePaths.isNotEmpty,
      filePaths: filePaths,
      cut: cut,
    );
  }

  @override
  Future<ClipboardSnapshot> readContent({
    bool includeImages = true,
    bool includeRich = false,
  }) async {
    await _checkRead();
    return ClipboardSnapshot(
      text,
      revision,
      html: html,
      rtf: rtf,
      ownWrite: own,
      sensitive: sensitive,
      png: includeImages ? png : null,
      hasImage: png != null,
      hasFiles: filePaths.isNotEmpty,
      filePaths: filePaths,
      cut: cut,
    );
  }

  @override
  Future<bool> writeImage(
    Uint8List bytes, {
    String? text,
    int? expectedRevision,
    String? html,
    String? rtf,
  }) async {
    final success = await write(
      text ?? '',
      expectedRevision: expectedRevision,
      html: html,
      rtf: rtf,
    );
    if (success) {
      png = bytes;
      this.text = text;
    }
    return success;
  }

  @override
  Future<bool> write(
    String value, {
    int? expectedRevision,
    String? html,
    String? rtf,
  }) async {
    writeAttempts++;
    if (busyWrites > 0) {
      busyWrites--;
      throw PlatformException(code: 'busy', message: 'Clipboard busy.');
    }
    final hook = beforeWrite;
    beforeWrite = null;
    hook?.call();
    if (expectedRevision != null && expectedRevision != revision) return false;
    virtualId = null;
    text = value;
    this.html = html;
    this.rtf = rtf;
    filePaths = [];
    cut = false;
    png = null;
    revision++;
    own = true;
    sensitive = false;
    writes++;
    if (unmarkedChangeAfterWrite) {
      // Android can report our own write again, without our marker.
      revision++;
      own = false;
    }
    if (busyAfterWrite != null) {
      readBusyUntil = DateTime.now().add(busyAfterWrite!);
      busyAfterWrite = null;
    }
    changes.add(null);
    return true;
  }

  void userCopy(
    String value, {
    bool private = false,
    String? html,
    String? rtf,
  }) {
    virtualId = null;
    text = value;
    this.html = html;
    this.rtf = rtf;
    filePaths = [];
    cut = false;
    png = null;
    stampValue++;
    revision++;
    own = false;
    sensitive = private;
    changes.add(null);
  }

  void userCopyImage(Uint8List bytes, {String? text, bool private = false}) {
    png = bytes;
    this.text = text;
    revision++;
    own = false;
    sensitive = private;
    changes.add(null);
  }
}

class FakeDiscovery extends LanDiscovery {
  @override
  Future<void> start() async {}
  @override
  Future<void> advertise(
    String id,
    String name,
    String address,
    int port,
  ) async {}
  @override
  Future<void> stopAdvertising() async {}
  @override
  Future<void> stop() async {}
}

Future<AppController> testController(
  Identity identity, {
  bool automatic = true,
  bool phone = false,
  bool backgroundReceive = false,
  // Text already on the clipboard before the app first looks at it.
  String? existingText,
  bool existingPrivate = false,
  // Existing protection tests opt out of the app's "newest copy wins" default.
  bool newestWins = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'automatic': automatic,
    'newestWins': newestWins,
    'backgroundReceive': backgroundReceive,
    'deviceName': identity.id,
  });
  final controller = AppController(
    identity: identity,
    trust: TrustStore(MemoryVault()),
    clipboard: FakeClipboard()
      ..text = existingText
      ..revision = existingText == null ? 0 : 1
      ..sensitive = existingPrivate,
    discovery: FakeDiscovery(),
    preferences: await SharedPreferences.getInstance(),
    mobileOverride: phone ? true : null,
  );
  await controller.initialize(discover: false, loadInterfaces: false);
  return controller;
}

Future<void> eventually(bool Function() predicate, {String? reason}) async {
  final clock = Stopwatch()..start();
  while (!predicate()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      throw StateError(reason ?? 'Condition did not become true.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}
