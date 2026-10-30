import 'dart:io';
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

Future<void> _captureDashboard(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('DASHBOARD_CAPTURE_DIR');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('dashboard-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

class _PreviewHost extends LocalHost {
  _PreviewHost()
    : super(Identity('host', '', ''), TrustStore(MemoryVault()), 'Host') {
    address = '192.168.1.5';
  }
  @override
  int get port => defaultPort;
  @override
  String get pairCode => '001234';
  @override
  Duration get inviteRemaining => const Duration(minutes: 2);
  @override
  Invitation invite() => Invitation(
    hostId: identity.id,
    address: address!,
    port: port,
    fingerprint: 'a' * 64,
    secret: randomSecret(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (const String.fromEnvironment('DASHBOARD_CAPTURE_DIR').isEmpty) return;
    final windows = Platform.environment['WINDIR'];
    if (windows != null) {
      final font = FontLoader('Segoe UI');
      for (final filename in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
        final bytes = await File('$windows/Fonts/$filename').readAsBytes();
        font.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await font.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'split workspace adapts without losing the draft or copying text',
    (tester) async {
      final app = await testController(
        Identity('Work laptop', '', ''),
        automatic: false,
      );
      app.selectedHost = SavedHost(
        id: 'host',
        name: 'Office PC',
        address: '192.168.1.5',
        port: defaultPort,
        fingerprint: 'a' * 64,
        credential: 'test',
      );
      app.connected = true;
      app.item = ClipItem(
        id: 'sample',
        sequence: 1,
        senderId: 'host',
        senderName: 'Office PC',
        text: 'Notes for the next device\n\nReview the draft, then send it when ready.',
        lifetime: const Duration(minutes: 5),
      );
      app.itemStatus = 'Available in app';
      app.status = 'Connected to Office PC';
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(() {
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearAllTestValues();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('dashboard-capture'),
          child: ClipboardApp(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connections-split')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('destination-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clipboard-split')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Latest shared text')).dy,
        tester.getTopLeft(find.text('Send text').first).dy,
      );
      expect(
        tester.getTopLeft(find.byType(TextField)).dx,
        greaterThan(tester.getTopLeft(find.text('Latest shared text')).dx),
      );
      await tester.enterText(
        find.byType(TextField),
        'Keep this draft across layouts',
      );
      await tester.pumpAndSettle();
      await _captureDashboard(tester, 'clipboard-1440');
      for (final width in [1120.0, 900.0, 390.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            ValueKey(width >= 1120 ? 'clipboard-split' : 'clipboard-stacked'),
          ),
          findsOneWidget,
        );
        expect(find.text('Keep this draft across layouts'), findsOneWidget);
        expect(find.text(app.item!.text), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _captureDashboard(tester, 'clipboard-${width.toInt()}');
      }
      app.item = ClipItem(
        id: 'long',
        sequence: 2,
        senderId: 'host',
        senderName: 'Office PC',
        text: 'x' * 60000,
        lifetime: const Duration(minutes: 5),
      );
      app.dismissError();
      tester.view.physicalSize = const Size(390, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField));
      expect(find.text('Keep this draft across layouts'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(1440, 900);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            highContrast: true,
          );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clipboard-stacked')), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      expect(find.text('Keep this draft across layouts'), findsOneWidget);
      expect((app.clipboard as FakeClipboard).writes, 0);
      expect(tester.takeException(), isNull);
      await _captureDashboard(tester, 'clipboard-large-dark');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('session group uses real members and one summary at each size', (
    tester,
  ) async {
    final app = await testController(
      Identity('Work laptop', '', ''),
      automatic: false,
    );
    app.host = _PreviewHost();
    app.connected = true;
    app.status = 'Hosting on 192.168.1.5:47321';
    app.members = [
      {'id': app.identity.id, 'name': app.name, 'host': true, 'online': true},
      {
        'id': 'peer',
        'name': 'Studio computer',
        'online': true,
        'status': 'needsAction',
      },
      {
        'id': 'offline',
        'name': 'Saved remote device with a long name',
        'online': false,
      },
    ];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('dashboard-capture'),
        child: ClipboardApp(controller: app),
      ),
    );
    await tester.pumpAndSettle();
    for (final width in [1440.0, 1120.0, 900.0, 390.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      expect(find.text(app.status), findsOneWidget);
      expect(find.text('${app.name} (you)'), findsNothing);
      expect(find.text('Studio computer'), findsOneWidget);
      expect(find.text('Available · copy on this device'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byTooltip('Revoke access'), findsNothing);
      expect(tester.takeException(), isNull);
      await _captureDashboard(tester, 'connections-${width.toInt()}');
    }
    await tester.ensureVisible(find.text('Change connection'));
    await tester.tap(find.text('Change connection'));
    await tester.pumpAndSettle();
    expect(find.text('Enter pairing code'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start session'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paused conflicts, approval and removed payload remain honest', (
    tester,
  ) async {
    final app = await testController(
      Identity('State preview', '', ''),
      automatic: false,
    );
    app.host = _PreviewHost();
    app.connected = true;
    app.paused = true;
    app.pendingPair = PairRequest(
      'request',
      'New device',
      address: '192.168.1.8',
    );
    app.item = ClipItem(
      id: 'private',
      sequence: 1,
      senderId: 'peer',
      senderName: 'Peer',
      text: 'Private preview text',
      lifetime: const Duration(minutes: 5),
    );
    app.conflictText = 'Preserved copy';
    app.error = 'Example recoverable error';
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('destination-1')));
    await tester.pumpAndSettle();
    expect(find.text('Accept device'), findsOneWidget);
    expect(find.text('Example recoverable error'), findsOneWidget);
    expect(find.text('Use received text'), findsOneWidget);
    expect(find.text('Send my text'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Copy'))
          .onPressed,
      isNull,
    );
    app.item = null;
    app.conflictText = null;
    app.dismissError();
    await tester.pump();
    expect(
      find.text('Private preview text', skipOffstage: false),
      findsNothing,
    );
    expect(find.text('No shared text yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle setup, saved hosts and keyboard pairing stay usable', (
    tester,
  ) async {
    final app = await testController(
      Identity('Work laptop', '', ''),
      automatic: false,
    );
    app.trust.hosts['saved'] = SavedHost(
      id: 'saved',
      name: 'Office PC',
      address: '192.168.1.5',
      port: defaultPort,
      fingerprint: 'a' * 64,
      credential: 'test',
    );
    tester.view.devicePixelRatio = 1;
    final strategy = FocusManager.instance.highlightStrategy;
    addTearDown(() {
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      FocusManager.instance.highlightStrategy = strategy;
    });
    tester.view.physicalSize = const Size(1440, 800);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('dashboard-capture'),
        child: ClipboardApp(controller: app),
      ),
    );
    await tester.pumpAndSettle();
    for (final width in [1440.0, 900.0, 390.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpAndSettle();
      expect(find.text('Office PC'), findsOneWidget);
      expect(find.text('Connect to Wi-Fi to start.'), findsOneWidget);
      expect(find.byTooltip('Session actions'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start session'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Enter pairing code'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await _captureDashboard(tester, 'setup-${width.toInt()}');
    }
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.ensureVisible(find.text('Enter pairing code'));
    Focus.of(tester.element(find.text('Enter pairing code'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    final route = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('pair-code'))),
    )!;
    expect(route.transitionDuration, Duration.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pair-code')), findsNothing);
    expect((app.clipboard as FakeClipboard).writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'file controls and progress fit narrow large-text and desktop layouts',
    (tester) async {
      final app = await testController(Identity('files', '', ''));
      (app.clipboard as FakeClipboard).filesEnabled = true;
      app.item = ClipItem(
        id: 'files',
        sequence: 1,
        senderId: 'other',
        senderName: 'Other PC',
        lifetime: fileLifetime,
        payload: ClipPayload.fromJson({
          'kind': 'files',
          'entries': [
            {'i': 0, 'path': 'Reports', 'dir': true},
            {'i': 1, 'path': 'Reports/a.zip', 'size': 100},
          ],
          'roots': ['Reports'],
          'totalBytes': 100,
          'fileCount': 1,
        }),
      );
      app.itemStatus = 'Download to copy files';
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearAllTestValues();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('dashboard-capture'),
          child: ClipboardApp(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clipboard').last);
      for (final width in [1440.0, 320.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.platformDispatcher.textScaleFactorTestValue = width == 320
            ? 2
            : 1;
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Download').last);
        expect(find.text('Reports'), findsOneWidget);
        expect(find.text('Download'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width == 1440) await _captureDashboard(tester, 'windows-files');
        app.imageProgress = 45;
        app.itemStatus = 'Downloading files 45%';
        app.notifyListeners();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Cancel').last);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.takeException(), isNull);
        app.imageProgress = null;
        app.notifyListeners();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('automatic sharing still requires explicit consent', (
    tester,
  ) async {
    final app = await testController(
      Identity('consent', '', ''),
      automatic: false,
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clipboard').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(SwitchListTile, 'Automatic clipboard sharing'),
    );
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Automatic clipboard sharing'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enable automatic sharing?'), findsOneWidget);
    expect(app.automatic, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.automatic, isFalse);
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Automatic clipboard sharing'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable sharing'));
    await tester.pumpAndSettle();
    expect(app.automatic, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('draft survives navigation and shared text stays literal', (
    tester,
  ) async {
    final app = await testController(
      Identity('draft', '', ''),
      automatic: false,
    );
    addTearDown(app.dispose);
    app.item = ClipItem(
      id: 'literal-item',
      sequence: 1,
      senderId: 'sender',
      senderName: 'Other device',
      text: '<script>alert(1)</script>\nhttps://example.com/private',
      lifetime: const Duration(minutes: 5),
    );
    app.conflictText = 'Preserved local text';
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clipboard').last);
    await tester.pumpAndSettle();
    expect(find.text(app.item!.text), findsOneWidget);
    expect(find.text('Use received text'), findsOneWidget);
    expect(find.text('Send my text'), findsOneWidget);
    final draft = find.byType(TextField);
    await tester.ensureVisible(draft);
    await tester.enterText(draft, 'Keep this draft');
    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clipboard').last);
    await tester.pumpAndSettle();
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(1100, 480),
  ]) {
    testWidgets('large-text dark layout and cancellable pairing at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            highContrast: true,
          );
      final app = await testController(
        Identity(
          'A very long local device name that must remain usable',
          '',
          '',
        ),
        automatic: false,
      );
      addTearDown(() {
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearAllTestValues();
      });
      await tester.pumpWidget(ClipboardApp(controller: app));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Enter pairing code'));
      await tester.tap(find.text('Enter pairing code'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-code')), findsNothing);
      for (final destination in ['Clipboard', 'Devices', 'Connections']) {
        await tester.ensureVisible(find.text(destination).last);
        await tester.tap(find.text(destination).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('pairing motion can reverse before the entrance settles', (
    tester,
  ) async {
    final app = await testController(
      Identity('motion', '', ''),
      automatic: false,
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Enter pairing code'));
    await tester.tap(find.text('Enter pairing code'));
    await tester.pump(const Duration(milliseconds: 40));
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop connections and clipboard screens render without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      final app = await testController(
        Identity('Test desktop', '', ''),
        automatic: false,
      );
      addTearDown(() {
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ClipboardApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.text('Connections'), findsWidgets);
      expect(find.text('Start session'), findsOneWidget);
      await tester.ensureVisible(find.text('Enter pairing code'));
      await tester.tap(find.text('Enter pairing code'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-address')), findsOneWidget);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter all six digits shown on the host.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      await tester.tap(find.text('Clipboard').first);
      await tester.pumpAndSettle();
      expect(find.text('Latest shared text'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('narrow layout provides navigation and usable manual joining', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final app = await testController(
      Identity('Test phone', '', ''),
      automatic: false,
    );
    addTearDown(() {
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    expect(find.text('Saved hosts'), findsOneWidget);
    await tester.tap(find.text('Connections').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Enter pairing code'));
    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.enterText(find.byKey(const ValueKey('pair-code')), '001 234');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('pair-code')))
          .controller!
          .text,
      '001234',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enter the local IPv4 address shown on the host, with its port if shown.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), null);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('nearby host is selected without needing an address or JSON', (
    tester,
  ) async {
    final app = await testController(
      Identity('client', '', ''),
      automatic: false,
    );
    addTearDown(app.dispose);
    app.discovery.hosts['host'] = NearbyHost(
      'host',
      'First PC',
      '192.168.1.5',
      defaultPort,
    );
    await tester.pumpWidget(ClipboardApp(controller: app));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Enter pairing code'));
    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    expect(find.text('First PC · 192.168.1.5'), findsOneWidget);
    expect(find.byKey(const ValueKey('pair-address')), findsNothing);
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone-size invitation shows a readable short code and copy action',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      final app = await testController(
        Identity('preview', '', ''),
        automatic: false,
      );
      app.host = _PreviewHost();
      app.connected = true;
      addTearDown(() {
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ClipboardApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add device').first);
      await tester.tap(find.text('Add device').first);
      await tester.pumpAndSettle();
      expect(find.text('001 234'), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);
      expect(find.text('192.168.1.5:47321'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.tap(find.text('Copy code'));
      await tester.pump();
      expect((app.clipboard as FakeClipboard).text, '001234');
      expect(app.host!.engine.item, null);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
