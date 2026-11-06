import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

// A phone joined to a PC. Real loopback TLS carries the session; the clipboard
// is the controllable fake, so no real clipboard is touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity certificate;
  late AppController pc;
  AppController? phone;
  StreamSubscription? approval;

  setUpAll(() {
    certificate = Identity.generate();
  });

  Future<AppController> join({
    bool background = false,
    String? existingText,
    bool existingPrivate = false,
  }) async {
    pc = await testController(
      Identity('PC', certificate.certificate, certificate.privateKey),
    );
    await pc.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = pc.host!.pairing.stream.listen((r) => r.decide(true));
    final joined = await testController(
      Identity('Phone', certificate.certificate, certificate.privateKey),
      phone: true,
      backgroundReceive: background,
      existingText: existingText,
      existingPrivate: existingPrivate,
    );
    await joined.pair(pc.host!.invite().encode());
    await eventually(() => pc.connected && joined.connected);
    phone = joined;
    return joined;
  }

  tearDown(() async {
    await approval?.cancel();
    await phone?.leave();
    await pc.leave();
    phone?.dispose();
    pc.dispose();
    phone = null;
  });

  FakeClipboard clipboardOf(AppController c) => c.clipboard as FakeClipboard;

  group('first connection', () {
    test(
      'text already on the phone does not block the first PC copy',
      () async {
        final p = await join(existingText: 'something copied earlier');
        final fake = clipboardOf(p);
        expect(fake.text, 'something copied earlier');
        await pc.sendText('fresh from the PC');
        await eventually(() => fake.text == 'fresh from the PC');
        await eventually(() => p.itemStatus == 'Ready to paste');
        // The old text was never shared.
        expect(pc.item?.text, 'fresh from the PC');
      },
    );

    test('a private phone copy still blocks the PC copy', () async {
      final p = await join(existingText: 'secret', existingPrivate: true);
      final fake = clipboardOf(p);
      await pc.sendText('fresh from the PC');
      await eventually(() => p.item?.text == 'fresh from the PC');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.text, 'secret');
    });
  });

  group('echoes of its own write', () {
    test(
      'extra change reports for received text are not shared back',
      () async {
        final p = await join();
        final fake = clipboardOf(p);
        await pc.sendText('from the PC');
        await eventually(() => p.itemStatus == 'Ready to paste');
        // Android (and the emulator) can report more changes with no marker.
        for (var i = 0; i < 2; i++) {
          fake.revision++;
          fake.own = false;
          fake.sensitive = false;
          fake.changes.add(null);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(pc.item?.senderId, 'PC');
        expect(p.item?.senderId, 'PC');
        // The next PC copy still arrives without a tap.
        await pc.sendText('second');
        await eventually(() => fake.text == 'second');
      },
    );
  });

  group('unmarked reports of its own write', () {
    test('still confirm the received text as ready to paste', () async {
      final p = await join();
      final fake = clipboardOf(p)..unmarkedChangeAfterWrite = true;
      await pc.sendText('first');
      await eventually(() => p.itemStatus == 'Ready to paste');
      expect(pc.item?.senderId, 'PC');
      await pc.sendText('second');
      await eventually(() => fake.text == 'second');
      await eventually(() => p.itemStatus == 'Ready to paste');
      expect(fake.writes, 2);
    });
  });

  group('window focus', () {
    test('a clipboard check refused at launch is retried', () async {
      pc = await testController(
        Identity('PC', certificate.certificate, certificate.privateKey),
      );
      await pc.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
      approval = pc.host!.pairing.stream.listen((r) => r.decide(true));
      final joined = await testController(
        Identity('Phone', certificate.certificate, certificate.privateKey),
        phone: true,
        existingText: 'old text',
      );
      phone = joined;
      final fake = clipboardOf(joined)
        ..readFailure = PlatformException(code: 'focus', message: 'No focus.');
      await joined.pair(pc.host!.invite().encode());
      await eventually(() => pc.connected && joined.connected);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pc.sendText('too early');
      await eventually(() => joined.item?.text == 'too early');
      expect(fake.text, 'old text');
      expect(joined.itemStatus, contains('could not be checked'));
      // The window gains focus; the next look succeeds with no tap.
      fake.readFailure = null;
      await eventually(() => fake.readAttempts >= 2);
      await pc.sendText('after focus');
      await eventually(() => fake.text == 'after focus');
      await eventually(() => joined.itemStatus == 'Ready to paste');
    });
  });

  group('opening the app', () {
    test(
      'applies the item copied on the PC while the app was closed',
      () async {
        final p = await join();
        final fake = clipboardOf(p);
        await pc.sendText('first');
        await eventually(() => fake.text == 'first');
        await p.setForeground(false);
        expect(p.connected, isFalse);
        await pc.sendText('while away');
        await p.setForeground(true);
        await eventually(() => fake.text == 'while away');
        await eventually(() => p.itemStatus == 'Ready to paste');
      },
    );

    test('keeps a copy made on the phone while the app was closed', () async {
      final p = await join();
      final fake = clipboardOf(p);
      await pc.sendText('first');
      await eventually(() => fake.text == 'first');
      await p.setForeground(false);
      fake.userCopy('copied on phone');
      await pc.sendText('while away');
      await p.setForeground(true);
      await eventually(() => p.item?.text == 'while away');
      expect(fake.text, 'copied on phone');
      expect(p.itemStatus, isNot('Ready to paste'));
    });

    test('does not rewrite an item it already showed', () async {
      final p = await join();
      final fake = clipboardOf(p);
      await pc.sendText('only item');
      await eventually(() => fake.text == 'only item');
      expect(fake.writes, 1);
      await p.setForeground(false);
      await p.setForeground(true);
      await eventually(() => p.connected && p.item?.text == 'only item');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.writes, 1);
    });

    test('keeps an old item from covering a private phone copy', () async {
      final p = await join();
      final fake = clipboardOf(p);
      await pc.sendText('old item');
      await eventually(() => fake.text == 'old item');
      fake.userCopy('secret', private: true);
      await p.setForeground(false);
      await p.setForeground(true);
      await eventually(() => p.connected && p.item?.text == 'old item');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.text, 'secret');
    });
  });

  group('receiving in the background', () {
    test('writes fresh PC text while the app is hidden', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p);
      await p.setBackgroundReceive(true);
      expect(fake.serviceStates.last, isTrue);
      await p.setForeground(false);
      expect(p.connected, isTrue);
      await pc.sendText('from the PC');
      await eventually(() => fake.text == 'from the PC');
      expect(fake.backgroundWrites, 1);
      await eventually(() => p.itemStatus == 'Ready to paste');
      expect(fake.receivedNotices, ['PC']);
      // The notice never carries the text.
      expect(fake.receivedNotices.join(), isNot(contains('from the PC')));
    });

    test('opening the app after a background write needs no tap', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p);
      await p.setBackgroundReceive(true);
      await p.setForeground(false);
      await pc.sendText('background copy');
      await eventually(() => fake.text == 'background copy');
      await p.setForeground(true);
      await pc.sendText('foreground copy');
      await eventually(() => fake.text == 'foreground copy');
      await eventually(() => p.itemStatus == 'Ready to paste');
    });

    test('keeps a newer phone copy and offers the item instead', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p);
      await p.setBackgroundReceive(true);
      await p.setForeground(false);
      fake.userCopy('copied on phone');
      await pc.sendText('from the PC');
      await eventually(() => p.item?.text == 'from the PC');
      await eventually(() => fake.receivedNotices.isNotEmpty);
      expect(fake.text, 'copied on phone');
      expect(fake.receivedNotices.single, 'action:PC');
      expect(p.itemStatus, contains('newer copy'));
    });

    test('replaces the clipboard when Android hides its change time', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p)..stampReadable = false;
      await p.setBackgroundReceive(true);
      await p.setForeground(false);
      fake.userCopy('copied on phone');
      await pc.sendText('from the PC');
      await eventually(() => fake.text == 'from the PC');
    });

    test('a blocked write offers a notification action', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p)..backgroundWriteDenied = true;
      await p.setBackgroundReceive(true);
      await p.setForeground(false);
      await pc.sendText('from the PC');
      await eventually(() => fake.receivedNotices.isNotEmpty);
      expect(fake.receivedNotices.single, 'action:PC');
      expect(fake.text, isNull);
      expect(p.itemStatus, contains('Could not copy in the background'));
    });

    test('paused phones and disabled mode write nothing', () async {
      final p = await join(background: true);
      final fake = clipboardOf(p);
      await p.setBackgroundReceive(true);
      await p.setForeground(false);
      await p.setPaused(true);
      await pc.sendText('while paused');
      await eventually(() => p.item?.text == 'while paused');
      expect(fake.backgroundWrites, 0);
      await p.setPaused(false);
      await p.setBackgroundReceive(false);
      expect(fake.serviceStates.last, isFalse);
      expect(p.connected, isFalse);
      expect(fake.backgroundWrites, 0);
    });

    test('leaving the session stops the service', () async {
      final p = await join(background: true);
      await p.setBackgroundReceive(true);
      await p.leave();
      expect(clipboardOf(p).serviceStates.last, isFalse);
    });
  });
}
