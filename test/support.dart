import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';
import 'package:local_clipboard/platform/discovery.dart';

class FakeClipboard extends ClipboardBridge {
  String? text;
  Uint8List? png;
  int revision = 0;
  bool own = false;
  bool sensitive = false;
  int writes = 0;
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
  Future<bool> writeFiles(List<String> paths, {int? expectedRevision}) async {
    final success = await write('', expectedRevision: expectedRevision);
    if (success) {
      filePaths = paths;
      text = null;
    }
    return success;
  }

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
  Future<ClipboardSnapshot> read() async {
    await _checkRead();
    return ClipboardSnapshot(
      text,
      revision,
      ownWrite: own,
      sensitive: sensitive,
      hasImage: png != null,
      hasFiles: filePaths.isNotEmpty,
      filePaths: filePaths,
      cut: cut,
    );
  }

  @override
  Future<ClipboardSnapshot> readContent({bool includeImages = true}) async {
    await _checkRead();
    return ClipboardSnapshot(
      text,
      revision,
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
  }) async {
    final success = await write(text ?? '', expectedRevision: expectedRevision);
    if (success) {
      png = bytes;
      this.text = text;
    }
    return success;
  }

  @override
  Future<bool> write(String value, {int? expectedRevision}) async {
    writeAttempts++;
    if (busyWrites > 0) {
      busyWrites--;
      throw PlatformException(code: 'busy', message: 'Clipboard busy.');
    }
    final hook = beforeWrite;
    beforeWrite = null;
    hook?.call();
    if (expectedRevision != null && expectedRevision != revision) return false;
    text = value;
    filePaths = [];
    cut = false;
    png = null;
    revision++;
    own = true;
    sensitive = false;
    writes++;
    if (busyAfterWrite != null) {
      readBusyUntil = DateTime.now().add(busyAfterWrite!);
      busyAfterWrite = null;
    }
    changes.add(null);
    return true;
  }

  void userCopy(String value, {bool private = false}) {
    text = value;
    filePaths = [];
    cut = false;
    png = null;
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
}) async {
  SharedPreferences.setMockInitialValues({
    'automatic': automatic,
    'deviceName': identity.id,
  });
  final controller = AppController(
    identity: identity,
    trust: TrustStore(MemoryVault()),
    clipboard: FakeClipboard(),
    discovery: FakeDiscovery(),
    preferences: await SharedPreferences.getInstance(),
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
