import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/app/ui.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';
import 'package:local_clipboard/platform/discovery.dart';
import 'package:local_clipboard/platform/secure_vault.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows native storage, clipboard listener, tray, and app startup',
    (tester) async {
      final vault = SecureVault();
      final identity = await Identity.load(vault);
      expect(identity.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      final restored = await Identity.load(vault);
      expect(restored.id, identity.id);
      expect(restored.fingerprint, identity.fingerprint);
      final trust = TrustStore(vault);
      await trust.load();
      SharedPreferences.setMockInitialValues({
        'automatic': false,
        'deviceName': 'Windows PC',
      });
      final controller = AppController(
        identity: identity,
        trust: trust,
        clipboard: ClipboardBridge(),
        discovery: LanDiscovery(),
        preferences: await SharedPreferences.getInstance(),
      );
      await controller.initialize(discover: false, loadInterfaces: false);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ClipboardApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy here.\nPaste over there.'), findsOneWidget);
      expect(tester.takeException(), null);
      Future<void> capture(String filename) => tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(
          const String.fromEnvironment(
            'ARTIFACT_DIR',
            defaultValue: 'artifacts',
          ),
        );
        await directory.create(recursive: true);
        await File('${directory.path}/$filename')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await capture('windows-overview.png');
      await tester.tap(find.text('Enter pairing code'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-address')), findsOneWidget);
      expect(tester.takeException(), null);
      await capture('windows-code-pairing.png');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clipboard').first);
      await tester.pumpAndSettle();
      expect(find.text('Your shared clipboard.'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
