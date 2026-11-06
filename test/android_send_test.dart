import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/core/protocol.dart';
import 'package:local_clipboard/platform/clipboard_bridge.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity certificate;
  late AppController pc;
  late AppController phone;
  StreamSubscription? approval;

  setUpAll(() => certificate = Identity.generate());
  setUp(() async {
    pc = await testController(
      Identity('PC', certificate.certificate, certificate.privateKey),
    );
    phone = await testController(
      Identity('Phone', certificate.certificate, certificate.privateKey),
      phone: true,
      automatic: false,
      backgroundReceive: true,
    );
  });
  tearDown(() async {
    await approval?.cancel();
    approval = null;
    await phone.leave();
    await pc.leave();
    phone.dispose();
    pc.dispose();
  });

  Future<void> pair() async {
    await pc.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
    approval = pc.host!.pairing.stream.listen((r) => r.decide(true));
    await phone.pair(pc.host!.invite().encode());
    await eventually(() => phone.connected && pc.connected);
  }

  test('Share delivers supplied text with automatic off and leaves the clipboard untouched', () async {
    await pair();
    final clipboard = phone.clipboard as FakeClipboard;
    clipboard.text = 'keep my clipboard';
    final writes = clipboard.writes;
    await phone.sendExternalText(
      ClipboardSnapshot('shared selection', 0),
      true,
    );
    expect(pc.item?.text, 'shared selection');
    expect(pc.item?.senderId, 'Phone');
    expect(phone.sending, false);
    expect(clipboard.text, 'keep my clipboard');
    expect(clipboard.writes, writes);
  });

  test('notification snapshot sends while the phone is hidden', () async {
    await pair();
    await phone.setForeground(false);
    await phone.sendExternalText(
      ClipboardSnapshot('copied in another app', 0),
      false,
    );
    expect(pc.item?.text, 'copied in another app');
    expect(pc.item?.senderId, 'Phone');
  });

  test('notification refuses sensitive and own-write snapshots', () async {
    await pair();
    for (final snapshot in [
      ClipboardSnapshot('private', 0, sensitive: true),
      ClipboardSnapshot('received', 0, ownWrite: true),
    ]) {
      await expectLater(
        phone.sendExternalText(snapshot, false),
        throwsA(isA<SessionException>()),
      );
    }
    expect(pc.item, isNull);
    // Directly selecting and sharing text is deliberate, like Paste & Send.
    await phone.sendExternalText(
      ClipboardSnapshot('selected private text', 0, sensitive: true),
      true,
    );
    expect(pc.item?.text, 'selected private text');
  });

  for (final newerCopy in [false, true]) {
    test(
      'notification acknowledgement permits the next PC copy; newer local copy=$newerCopy',
      () async {
        await pair();
        await phone.setAutomatic(true);
        await phone.setForeground(false);
        final clipboard = phone.clipboard as FakeClipboard;
        clipboard.userCopy('phone copy');
        final snapshot = ClipboardSnapshot(
          clipboard.text,
          clipboard.revision,
          changeStamp: clipboard.stampValue,
        );
        await phone.sendExternalText(snapshot, false);
        if (newerCopy) clipboard.userCopy('keep this newer copy');
        await pc.sendText('next PC copy');
        await eventually(() => phone.item?.text == 'next PC copy');
        if (newerCopy) {
          await eventually(() => phone.itemStatus.startsWith('A newer copy'));
          expect(clipboard.text, 'keep this newer copy');
        } else {
          await eventually(() => clipboard.text == 'next PC copy');
          expect(phone.itemStatus, 'Ready to paste');
        }
      },
    );
  }

  test(
    'notification suppresses received-text echo even without the native marker',
    () async {
      await pair();
      await phone.setAutomatic(true);
      await pc.sendText('from PC');
      await eventually(() => phone.itemStatus == 'Ready to paste');
      final id = pc.item!.id;
      await expectLater(
        phone.sendExternalText(ClipboardSnapshot('from PC', 0), false),
        throwsA(isA<SessionException>()),
      );
      expect(pc.item!.id, id);
    },
  );

  test('unpaired send has an actionable error and no publication', () async {
    await expectLater(
      phone.sendExternalText(ClipboardSnapshot('hello', 0), true),
      throwsA(
        isA<SessionException>().having(
          (e) => e.message,
          'message',
          contains('pair'),
        ),
      ),
    );
    expect(phone.sending, false);
  });

  test('saved host reconnects before sending', () async {
    await pair();
    await phone.setForeground(false);
    phone.connected = false;
    // The real saved pairing / pinned certificate is reused.
    await phone.sendExternalText(ClipboardSnapshot('after reconnect', 0), true);
    expect(pc.item?.text, 'after reconnect');
  });

  test('Share from another app reconnects without background receive and releases the connection', () async {
    await pair();
    await phone.setBackgroundReceive(false);
    await phone.setForeground(false);
    expect(phone.connected, false);
    await phone.sendExternalText(
      ClipboardSnapshot('shared without service', 0),
      true,
    );
    expect(pc.item?.text, 'shared without service');
    expect(phone.connected, false);
    expect(phone.active, false);
  });

  test(
    'unreachable saved host never reports success or queues clipboard text',
    () async {
      await pair();
      final saved = phone.selectedHost!;
      await pc.leave();
      await eventually(() => !phone.connected);
      saved.port = 1;
      await expectLater(
        phone.sendExternalText(ClipboardSnapshot('offline text', 0), true),
        throwsA(isA<SessionException>()),
      );
      expect(phone.sending, false);
    },
  );

  test(
    'paused send is refused and empty, null and oversize text are rejected',
    () async {
      await pair();
      await phone.setPaused(true);
      await expectLater(
        phone.sendExternalText(ClipboardSnapshot('hello', 0), true),
        throwsA(isA<SessionException>()),
      );
      await phone.setPaused(false);
      for (final text in <String?>[
        null,
        '',
        'bad\u0000text',
        List.filled(32769, 'é').join(),
      ]) {
        await expectLater(
          phone.sendExternalText(ClipboardSnapshot(text, 0), true),
          throwsFormatException,
        );
      }
      expect(pc.item, isNull);
    },
  );
}
