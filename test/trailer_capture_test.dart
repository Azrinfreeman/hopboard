// Safe marketing captures: real widgets, fictional state, no native clipboard/network.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/ui.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/core/host.dart';
import 'package:local_clipboard/core/protocol.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/platform/discovery.dart';
import 'support.dart';

class DemoHost extends LocalHost {
  DemoHost() : super(Identity('demo-host', '', ''), TrustStore(MemoryVault()), 'Studio PC') { address = '192.168.1.5'; }
  @override int get port => defaultPort;
  @override String get pairCode => '001234';
  @override Duration get inviteRemaining => const Duration(minutes: 2);
  @override Invitation invite() => Invitation(hostId: identity.id, address: address!, port: port, fingerprint: 'a' * 64, secret: randomSecret());
}

void main() {
  setUpAll(() async {
    for (final family in ['Segoe UI', 'Roboto', 'Ahem']) {
      final font = FontLoader(family);
      for (final name in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
        font.addFont(Future.value(ByteData.sublistView(await File('${Platform.environment['WINDIR']}/Fonts/$name').readAsBytes())));
      }
      await font.load();
    }
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('capture fictional Hopboard trailer states', (tester) async {
    final root = const String.fromEnvironment('TRAILER_CAPTURE_DIR');
    if (root.isEmpty) return;
    final app = await testController(Identity('Studio PC', '', ''), automatic: false);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() { app.dispose(); tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); tester.platformDispatcher.clearAllTestValues(); });
    const key = ValueKey('capture');
    ThemeData captureTheme(Brightness brightness) {
      final theme = appTheme(brightness: brightness);
      // Test engine has no system font fallback for dialog styles with no family.
      return theme.copyWith(dialogTheme: theme.dialogTheme.copyWith(
        titleTextStyle: theme.dialogTheme.titleTextStyle!.copyWith(fontFamily: 'Segoe UI'),
        contentTextStyle: theme.dialogTheme.contentTextStyle!.copyWith(fontFamily: 'Segoe UI'),
      ));
    }
    await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: captureTheme(Brightness.light), darkTheme: captureTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: ClipboardHome(controller: app),
    )));
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(root).create(recursive: true);
        await File('$root/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await capture('connections');
    app.discovery.hosts['studio'] = NearbyHost('studio', 'Studio PC', '192.168.1.5', defaultPort);
    await tester.tap(find.text('Enter pairing code').first); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pair-code')), '001234');
    await tester.pumpAndSettle(); await capture('join-code');
    final joinRect = tester.getRect(find.byType(AlertDialog));
    await tester.runAsync(() => File('$root/join-dialog.json').writeAsString(jsonEncode({'x':joinRect.left,'y':joinRect.top,'w':joinRect.width,'h':joinRect.height})));
    await tester.tap(find.text('Cancel')); await tester.pumpAndSettle();
    app.discovery.hosts.clear();
    app.host = DemoHost(); app.connected = true; app.status = 'Hosting on 192.168.1.5:47321';
    app.members = [{'id': app.identity.id, 'name': app.name, 'host': true, 'online': true}, {'id': 'laptop', 'name': 'Work laptop', 'online': true}, {'id': 'phone', 'name': 'Android phone', 'online': true}];
    app.notifyListeners(); await tester.pumpAndSettle();
    await capture('session');
    await tester.tap(find.text('Add device').first); await tester.pumpAndSettle();
    await capture('pairing');
    Navigator.of(tester.element(find.byKey(const ValueKey('destination-1')))).pop(); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('destination-1'))); await tester.pumpAndSettle();
    app.item = ClipItem(id: 'demo', sequence: 1, senderId: 'laptop', senderName: 'Work laptop', text: 'The next idea starts here.\n\nCopy on your laptop. Keep going on your PC.', lifetime: const Duration(minutes: 5));
    app.itemStatus = 'Ready to paste'; app.automatic = true;
    app.notifyListeners(); await tester.pumpAndSettle();
    await capture('clipboard');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle(); await capture('clipboard-dark');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle(); await capture('phone');
    tester.view.physicalSize = const Size(1440, 900);
    (app.clipboard as FakeClipboard).filesEnabled = true;
    app.item = ClipItem(id: 'files', sequence: 2, senderId: 'laptop', senderName: 'Work laptop', lifetime: fileLifetime, payload: ClipPayload.fromJson({'kind': 'files', 'entries': [{'i': 0, 'path': 'Project assets', 'dir': true}, {'i': 1, 'path': 'Project assets/Launch.zip', 'size': 8388608}], 'roots': ['Project assets'], 'totalBytes': 8388608, 'fileCount': 1}));
    app.itemStatus = 'Download to copy files';
    app.notifyListeners(); await tester.pumpAndSettle(); await capture('files');
    await tester.ensureVisible(find.text('Download').last); await tester.pumpAndSettle(); await capture('files-download');
    await tester.tap(find.byKey(const ValueKey('destination-2'))); await tester.pumpAndSettle(); await capture('devices');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
