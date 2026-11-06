import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/app/controller.dart';
import 'package:local_clipboard/core/content.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/discovery.dart';

import 'support.dart';

const html =
    'Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000163\r\n'
    'StartFragment:0000000141\r\nEndFragment:0000000127\r\n'
    '<html><body><!--StartFragment--><b>Bold</b><!--EndFragment--></body></html>';
const rtf = r'{\rtf1\ansi {\b Bold}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('payload', () {
    test('text keeps HTML and RTF through JSON', () {
      final payload = ClipPayload.fromJson({
        'text': 'Bold',
        ...richFields(html, rtf),
      });
      final again = ClipPayload.fromJson(payload.toJson());
      expect(again.html, html);
      expect(again.rtf, rtf);
      expect(again.text, 'Bold');
    });

    test('plain payloads are unchanged on the wire', () {
      final json = ClipPayload.fromJson({'text': 'plain'}).toJson();
      expect(json, {'text': 'plain'});
    });

    test('oversized formats are dropped by the sender, RTF first', () {
      final big = 'x' * (maxRichBytes - 10);
      final fields = richFields(html, big);
      expect(fields['html'], html);
      expect(fields.containsKey('rtf'), isFalse);
      expect(richFields('x' * (maxRichBytes + 1), rtf), {'rtf': rtf});
      expect(richFields('', null), isEmpty);
    });

    test('receivers reject oversized or invalid formats', () {
      expect(
        () => ClipPayload.fromJson({
          'text': 'a',
          'html': 'x' * (maxRichBytes - 5),
          'rtf': 'y' * 10,
        }),
        throwsFormatException,
      );
      expect(
        () => ClipPayload.fromJson({'text': 'a', 'rtf': 'bad\u0000'}),
        throwsFormatException,
      );
      expect(
        () => ClipPayload.fromJson({'text': 'a', 'html': 7}),
        throwsFormatException,
      );
    });
  });

  group('session', () {
    late Identity certificate;
    late AppController a;
    late AppController b;
    StreamSubscription? approval;

    setUpAll(() => certificate = Identity.generate());
    setUp(() async {
      a = await testController(
        Identity('Desktop A', certificate.certificate, certificate.privateKey),
        newestWins: true,
      );
      b = await testController(
        Identity('Desktop B', certificate.certificate, certificate.privateKey),
        newestWins: true,
      );
      await a.startHost(LanInterface('loopback', '127.0.0.1'), port: 0);
      approval = a.host!.pairing.stream.listen((r) => r.decide(true));
      await b.pair(a.host!.invite().encode());
      await eventually(() => a.connected && b.connected);
    });
    tearDown(() async {
      await approval?.cancel();
      await b.leave();
      await a.leave();
      a.dispose();
      b.dispose();
    });

    test('formatted text arrives formatted in both directions', () async {
      final ca = a.clipboard as FakeClipboard;
      final cb = b.clipboard as FakeClipboard;
      ca.userCopy('Bold', html: html, rtf: rtf);
      await eventually(() => cb.text == 'Bold');
      expect(cb.html, html);
      expect(cb.rtf, rtf);
      cb.userCopy('Plain again');
      await eventually(() => ca.text == 'Plain again');
      expect(ca.html, isNull);
      expect(ca.rtf, isNull);
    });
  });
}
