// A stand-in "PC" for testing the Android app on an emulator.
//
// It runs the real Hopboard host and controller over real TLS, but with the
// fake clipboard from test/support.dart, so it never reads or changes this
// computer's clipboard and does not touch an installed Hopboard.
//
// Run (keeps running until it receives `quit` or 3 hours pass):
//   flutter test tools/emulator_host_harness.dart --no-pub
//
// Control it by appending one command per line to build/emu/cmd.txt:
//   code            write a fresh pairing code and address to build/emu/host.txt
//   send <text>     share text from this PC to the phone
//   status          write session members and the latest item to host.log
//   quit            stop
// Output goes to build/emu/host.log and build/emu/host.txt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/identity.dart';
import 'package:local_clipboard/platform/discovery.dart';

import '../test/support.dart';

const _hostAddress = String.fromEnvironment(
  'HOST_ADDRESS',
  defaultValue: '192.168.1.100',
);
const _hostPort = int.fromEnvironment('HOST_PORT', defaultValue: 47399);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host for the emulator', () async {
    final folder = Directory('build/emu')..createSync(recursive: true);
    final command = File('${folder.path}/cmd.txt')..writeAsStringSync('');
    final log = File('${folder.path}/host.log')..writeAsStringSync('');
    final info = File('${folder.path}/host.txt');
    void note(String line) => log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $line\n',
      mode: FileMode.append,
    );

    // Keep one identity between runs, so a phone paired once stays paired.
    final identityFile = File('${folder.path}/identity.json');
    final Identity certificate;
    if (identityFile.existsSync()) {
      final saved = jsonDecode(identityFile.readAsStringSync()) as Map;
      certificate = Identity(
        'Test PC',
        saved['certificate'] as String,
        saved['privateKey'] as String,
      );
    } else {
      certificate = Identity.generate();
      identityFile.writeAsStringSync(
        jsonEncode({
          'certificate': certificate.certificate,
          'privateKey': certificate.privateKey,
        }),
      );
    }
    final pc = await testController(
      Identity('Test PC', certificate.certificate, certificate.privateKey),
    );
    await pc.startHost(LanInterface('lan', _hostAddress), port: _hostPort);
    final approval = pc.host!.pairing.stream.listen((request) {
      note('pairing request approved');
      request.decide(true);
    });
    pc.addListener(
      () => note(
        'members=${pc.members.length} connected=${pc.connected} '
        'item=${pc.item?.kind} status=${pc.itemStatus}',
      ),
    );

    void writeCode() {
      final invitation = pc.host!.invite();
      info.writeAsStringSync(
        'address=$_hostAddress:$_hostPort\ncode=${pc.host!.pairCode}\n'
        'invitation=${invitation.encode()}\n',
      );
      note('new pairing code written to host.txt');
    }

    writeCode();
    note('listening on $_hostAddress:$_hostPort');

    final deadline = DateTime.now().add(const Duration(hours: 3));
    var offset = 0;
    var quit = false;
    while (!quit && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final text = command.readAsStringSync();
      if (text.length <= offset) continue;
      for (final line in text.substring(offset).split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed == 'quit') {
          quit = true;
        } else if (trimmed == 'code') {
          writeCode();
        } else if (trimmed == 'status') {
          note(
            'STATUS members=${pc.members.map((m) => m['name']).toList()} '
            'item=${pc.item?.text} receipts=${pc.item == null ? '-' : 'see members'}',
          );
        } else if (trimmed.startsWith('send ')) {
          final value = trimmed.substring(5);
          try {
            await pc.sendText(value);
            note('sent ${value.length} characters');
          } catch (error) {
            note('send failed: $error');
          }
        }
      }
      offset = text.length;
    }
    await approval.cancel();
    await pc.leave();
    pc.dispose();
    note('stopped');
  }, timeout: Timeout.none);
}
