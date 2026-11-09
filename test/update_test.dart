import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/version.dart';
import 'package:local_clipboard/platform/update_service.dart';

void main() {
  test('versions compare release, prerelease and build metadata correctly', () {
    expect(compareVersions('0.2.0', '0.2.0-dev'), greaterThan(0));
    expect(compareVersions('v0.2.0+4', '0.2.0+5'), 0);
    expect(compareVersions('0.2.0-rc.10', '0.2.0-rc.2'), greaterThan(0));
    expect(compareVersions('0.1.2', '0.2.0-dev'), lessThan(0));
    expect(compareVersions('../../installer', '0.2.0'), null);
  });

  final keys = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final publicPem = CryptoUtils.encodeRSAPublicKeyToPem(
    keys.publicKey as RSAPublicKey,
  );
  Uint8List sign(List<int> data, [AsymmetricKeyPair? pair]) =>
      CryptoUtils.rsaSign(
        (pair ?? keys).privateKey as RSAPrivateKey,
        Uint8List.fromList(data),
      );

  // 'ok' = signed and intact; 'corrupt' = signed but wrong bytes;
  // 'forged' = manifest signed with a key the app does not pin.
  for (final mode in ['ok', 'corrupt', 'forged']) {
    final corrupt = mode == 'corrupt';
    test(
      'update download is explicit, bounded and signed ($mode)',
      () async {
        final base = await Directory.systemTemp.createTemp(
          'hopboard-update-test-',
        );
        addTearDown(() => base.delete(recursive: true));
        final bytes = utf8.encode('an offline installer fixture');
        final hash = sha256.convert(bytes).toString();
        const filename = 'Hopboard-Setup-99.0.0-x64.exe';
        const prefix =
            'https://github.com/Azrinfreeman/hopboard/releases/download/v99.0.0/';
        final manifest = utf8.encode(
          jsonEncode({
            'version': '99.0.0',
            'filename': filename,
            'size': bytes.length,
            'sha256': hash,
          }),
        );
        final signature = base64.encode(
          sign(manifest, mode == 'forged'
              ? CryptoUtils.generateRSAKeyPair(keySize: 2048)
              : null),
        );
        final requested = <Uri>[];
        final service = UpdateService(
          publicKeyPem: publicPem,
          directory: () async => base,
          fetch: (uri) async* {
            requested.add(uri);
            if (uri == UpdateService.releases) {
              yield utf8.encode(
                jsonEncode({
                  'tag_name': 'v99.0.0',
                  'assets': [
                    {
                      'name': filename,
                      'size': bytes.length,
                      'browser_download_url': '$prefix$filename',
                    },
                    {
                      'name': '$filename.manifest.json',
                      'browser_download_url': '$prefix$filename.manifest.json',
                    },
                    {
                      'name': '$filename.manifest.sig',
                      'browser_download_url': '$prefix$filename.manifest.sig',
                    },
                  ],
                }),
              );
            } else if (uri.path.endsWith('.manifest.json')) {
              yield manifest;
            } else if (uri.path.endsWith('.manifest.sig')) {
              yield utf8.encode(signature);
            } else {
              yield corrupt ? List.filled(bytes.length, 0) : bytes;
            }
          },
        );
        expect(requested, isEmpty);
        if (mode == 'forged') {
          await expectLater(service.prepare(), throwsFormatException);
          expect(requested.length, 3, reason: 'installer is never downloaded');
          return;
        }
        if (corrupt) {
          await expectLater(service.prepare(), throwsFormatException);
          expect(await base.list().length, 0);
        } else {
          final update = (await service.prepare())!;
          expect(await update.file.readAsBytes(), bytes);
          expect(update.hash, hash);
          expect(update.version, '99.0.0');
          await update.discard();
          expect(await base.list().length, 0);
        }
        expect(requested.length, 4);
      },
    );
  }

  test(
    'updater rejects HTTP, unexpected hosts and other repositories',
    () async {
      expect(UpdateService.allowed(Uri.parse('http://github.com/a')), false);
      expect(UpdateService.allowed(Uri.parse('https://evil.example/a')), false);
      expect(
        UpdateService.allowed(Uri.parse('https://github.com:8443/a')),
        false,
      );
      var requests = 0;
      final service = UpdateService(
        fetch: (_) async* {
          requests++;
          yield utf8.encode(
            jsonEncode({
              'tag_name': '99.0.0',
              'assets': [
                {
                  'name': 'Hopboard-Setup-99.0.0-x64.exe',
                  'size': 1,
                  'browser_download_url':
                      'https://github.com/other/repo/installer.exe',
                },
                {
                  'name': 'Hopboard-Setup-99.0.0-x64.exe.manifest.json',
                  'browser_download_url':
                      'https://github.com/other/repo/manifest',
                },
              ],
            }),
          );
        },
      );
      await expectLater(service.prepare(), throwsFormatException);
      expect(requests, 1);
    },
  );
}
