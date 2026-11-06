import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

// "Newest copy wins": a live copy from any device replaces every other
// device's clipboard without a manual Copy, in both directions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity certificate;
  late AppController a;
  late AppController b;
  StreamSubscription? approval;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  setUpAll(() => certificate = Identity.generate());

  Future<void> start({
    String? existingText,
    bool existingPrivate = false,
  }) async {
    a = await testController(
      Identity('Desktop A', certificate.certificate, certificate.privateKey),
      newestWins: true,
    );
    b = await testController(
      Identity('Desktop B', certificate.certificate, certificate.privateKey),
      newestWins: true,
      existingText: existingText,
      existingPrivate: existingPrivate,
    );
    await a.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = a.host!.pairing.stream.listen((request) => request.decide(true));
    await b.pair(a.host!.invite().encode());
    await eventually(() => a.connected && b.connected);
  }

  tearDown(() async {
    await approval?.cancel();
    await b.leave();
    await a.leave();
    a.dispose();
    b.dispose();
  });

  test('a private local copy no longer blocks later host copies', () async {
    await start();
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    cb.userCopy('guest password', private: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.host!.engine.item, isNull, reason: 'private copies never sent');
    for (final text in ['host one', 'host two']) {
      ca.userCopy(text);
      await eventually(
        () => cb.text == text && b.itemStatus == 'Ready to paste',
        reason: 'host copy "$text" was not applied',
      );
    }
    expect(b.hasConflict, isFalse);
  });

  test(
    'pre-existing guest content is replaced by the next live copy',
    () async {
      await start(existingText: 'old private text', existingPrivate: true);
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      ca.userCopy('fresh from host');
      await eventually(
        () => cb.text == 'fresh from host' && b.itemStatus == 'Ready to paste',
      );
    },
  );

  test('images replace a protected local copy', () async {
    await start();
    await a.setAutomaticImages(true);
    await b.setAutomaticImages(true);
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    cb.userCopy('guest secret', private: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    ca.userCopyImage(png);
    await eventually(() => cb.png != null && b.itemStatus == 'Ready to paste');
  });

  test('two-way: guest copies still reach the host', () async {
    await start();
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    ca.userCopy('from host');
    await eventually(() => cb.text == 'from host');
    cb.userCopy('from guest');
    await eventually(
      () => ca.text == 'from guest' && a.itemStatus == 'Ready to paste',
    );
  });

  test('a race settles on one copy everywhere without a conflict', () async {
    await start();
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    ca.userCopy('host side');
    cb.userCopy('guest side');
    await eventually(
      () =>
          ca.text != null &&
          ca.text == cb.text &&
          a.host!.engine.item?.text == ca.text,
      reason: 'clipboards did not converge',
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(ca.text, cb.text);
    expect(a.hasConflict || b.hasConflict, isFalse);
  });

  test('a copied invitation is still never replaced', () async {
    await start();
    final ca = a.clipboard as FakeClipboard;
    final cb = b.clipboard as FakeClipboard;
    await a.copyInvitation('private pairing material');
    cb.userCopy('ordinary shared text');
    await eventually(() => a.item?.text == 'ordinary shared text');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ca.text, 'private pairing material');
  });
}
