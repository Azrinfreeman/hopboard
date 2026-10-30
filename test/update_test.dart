import 'dart:convert';
import 'dart:io';

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

  for (final corrupt in [false, true]) {
    test(
      'update download is explicit, bounded and ${corrupt ? 'rejects corruption' : 'verified'}',
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
        final requested = <Uri>[];
        final service = UpdateService(
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
                      'name': '$filename.sha256',
                      'browser_download_url': '$prefix$filename.sha256',
                    },
                  ],
                }),
              );
            } else if (uri.path.endsWith('.sha256')) {
              yield utf8.encode('$hash  $filename');
            } else {
              yield corrupt ? List.filled(bytes.length, 0) : bytes;
            }
          },
        );
        expect(requested, isEmpty);
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
        expect(requested.length, 3);
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
                  'name': 'Hopboard-Setup-99.0.0-x64.exe.sha256',
                  'browser_download_url':
                      'https://github.com/other/repo/checksum',
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
