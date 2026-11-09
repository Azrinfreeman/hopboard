// Offline release-signing helper for the Windows updater.
//
//   dart run tools/update_signing.dart generate <private-key-file>
//       Creates an RSA-3072 key. Keep the private file OFF this repository and
//       off GitHub (password manager / encrypted drive). Prints the public PEM
//       to paste into UpdateService.updateSigningPublicKeyPem.
//   dart run tools/update_signing.dart sign <private-key-file> <installer.exe>
//       Writes <installer>.manifest.json and <installer>.manifest.sig next to
//       the installer. Upload both with the installer to the GitHub release.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

final _name = RegExp(r'^Hopboard-Setup-(\S+)-x64\.exe$');

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[0] == 'generate') {
    final file = File(args[1]);
    if (await file.exists()) {
      stderr.writeln('Refusing to overwrite ${file.path}.');
      exit(1);
    }
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 3072);
    await file.writeAsString(
      CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(pair.privateKey as RSAPrivateKey),
    );
    stdout.writeln('Private key written to ${file.path}. Back it up; never commit it.');
    stdout.writeln('Public key to pin in the app:\n');
    stdout.writeln(
      CryptoUtils.encodeRSAPublicKeyToPem(pair.publicKey as RSAPublicKey),
    );
  } else if (args.length == 3 && args[0] == 'sign') {
    final installer = File(args[2]);
    final match = _name.firstMatch(installer.uri.pathSegments.last);
    if (match == null) {
      stderr.writeln('Installer must be named Hopboard-Setup-<version>-x64.exe.');
      exit(1);
    }
    final key = CryptoUtils.rsaPrivateKeyFromPemPkcs1(
      await File(args[1]).readAsString(),
    );
    final bytes = await installer.readAsBytes();
    final manifest = utf8.encode(
      jsonEncode({
        'version': match[1],
        'filename': installer.uri.pathSegments.last,
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      }),
    );
    final signature = CryptoUtils.rsaSign(key, Uint8List.fromList(manifest));
    await File('${installer.path}.manifest.json').writeAsBytes(manifest);
    await File('${installer.path}.manifest.sig')
        .writeAsString(base64.encode(signature));
    stdout.writeln('Wrote manifest and signature for ${installer.path}.');
  } else {
    stderr.writeln('Usage: generate <private-key-file> | sign <private-key-file> <installer.exe>');
    exit(64);
  }
}
