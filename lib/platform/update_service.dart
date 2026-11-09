import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart' show CryptoUtils;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/version.dart';

class PreparedUpdate {
  PreparedUpdate(this.version, this.file, this.hash);
  final String version, hash;
  final File file;
  Future<void> discard() async {
    if (await file.parent.exists()) await file.parent.delete(recursive: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}

class UpdateService {
  UpdateService({this.fetch, this.directory, String? publicKeyPem})
    : publicKeyPem = publicKeyPem ?? updateSigningPublicKeyPem;
  // Injection keeps updater tests entirely offline.
  final Stream<List<int>> Function(Uri)? fetch;
  final Future<Directory> Function()? directory;
  final String publicKeyPem;

  /// RSA-3072 public key (PEM, "BEGIN PUBLIC KEY") of the offline release key.
  /// Generate it with `dart run tools/update_signing.dart generate`; until
  /// one is pinned here every update is refused.
  static const updateSigningPublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAjyaQ5c23h7ET/P94KMNX
ahuDCmeQXDenvLJbDmR3P+G9ES4nsFOeJWc2Z4f0zItISs74hb1moLkX3lSikYxs
46NYZAK451WfKXu8Cfo8r6cebby+e9Y2gBM4HrLSNgyCiqzVIYzIsQnAUQ1vxT/y
U4hP3/zA9iV6SVvrPdLXfuPTSO6hVhDeFXy3ncZ2Fvt03dNs2bnImtcgr6BMfOsj
dwrlNRiuEjHH077+IumndLtL83MpZo8LFDkUdhY1bWmp6U0fVoUdMSabVvAW/m4k
itNqVNfxvnjd4QH+EK1iF4lzg/4qq196uN5XfzwUXdud5d6s8udItJrgVmKoivb7
AS+1bPT05YCuqMxvUzYIbQWiRyQMrs0i7uFqHFPJGWmf4UN4oPhD+cVcxAlcEneg
Gmxt6DcYAnhN61XsTAVhiAsJNggwdbv1pU/N2yotQcyjhIrbY9hAm7ciX1yNvu/M
VstIi9VAF0fuv4Hkq3m1Barc55MQmBva7vzB4SUK8RQ9AgMBAAE=
-----END PUBLIC KEY-----
''';

  static bool verifyManifestSignature(
    Uint8List manifest,
    Uint8List signature,
    String pem,
  ) {
    if (pem.trim().isEmpty) return false;
    try {
      return CryptoUtils.rsaVerify(
        CryptoUtils.rsaPublicKeyFromPem(pem),
        manifest,
        signature,
        algorithm: 'SHA-256/RSA',
      );
    } catch (_) {
      return false;
    }
  }
  static const _channel = MethodChannel('dev.localclipboard/native');
  static final releases = Uri.https(
    'api.github.com',
    '/repos/Azrinfreeman/hopboard/releases/latest',
  );

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  Stream<List<int>> _request(Uri uri) async* {
    if (!allowed(uri)) throw const FormatException('Untrusted update address.');
    if (fetch != null) {
      yield* fetch!(uri);
      return;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var address = uri;
      for (var redirects = 0; redirects <= 5; redirects++) {
        if (!allowed(address)) {
          throw const FormatException('Untrusted update redirect.');
        }
        final request = await client.getUrl(address);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Hopboard/$applicationVersion',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const FormatException('Invalid update redirect.');
          }
          address = address.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw SessionException(
            'The update could not be downloaded. Try again later.',
          );
        }
        yield* response.timeout(const Duration(seconds: 30));
        return;
      }
      throw const FormatException('Too many update redirects.');
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _small(Uri uri, int limit) async {
    final result = <int>[];
    await for (final chunk in _request(uri)) {
      if (result.length + chunk.length > limit) {
        throw const FormatException('Update response is too large.');
      }
      result.addAll(chunk);
    }
    return result;
  }

  Future<PreparedUpdate?> prepare({void Function(double)? progress}) async {
    Directory? folder;
    try {
      final metadata =
          jsonDecode(utf8.decode(await _small(releases, 1024 * 1024))) as Map;
      final tag = metadata['tag_name'] as String;
      final newer = compareVersions(tag, applicationVersion);
      if (newer == null ||
          metadata['draft'] == true ||
          metadata['prerelease'] == true) {
        throw const FormatException('The release information is invalid.');
      }
      if (newer <= 0) return null;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      final filename = 'Hopboard-Setup-$version-x64.exe';
      final assets = (metadata['assets'] as List).cast<Map>();
      Map asset(String name) => assets.singleWhere((a) => a['name'] == name);
      Uri address(Map asset) {
        final uri = Uri.parse(asset['browser_download_url'] as String);
        if (!allowed(uri) ||
            uri.host != 'github.com' ||
            !uri.path.startsWith('/Azrinfreeman/hopboard/releases/download/')) {
          throw const FormatException('Untrusted release asset.');
        }
        return uri;
      }

      final installer = asset(filename);
      final expectedSize = installer['size'];
      if (expectedSize is! int ||
          expectedSize < 1 ||
          expectedSize > 256 * 1024 * 1024) {
        throw const FormatException('Unsupported installer size.');
      }
      // Authenticity: the manifest must carry the maintainer's offline
      // signature. A checksum hosted next to the installer proves nothing.
      final manifestBytes = Uint8List.fromList(
        await _small(address(asset('$filename.manifest.json')), 4096),
      );
      final signature = base64.decode(
        utf8
            .decode(await _small(address(asset('$filename.manifest.sig')), 4096))
            .trim(),
      );
      if (!verifyManifestSignature(
        manifestBytes,
        Uint8List.fromList(signature),
        publicKeyPem,
      )) {
        throw const FormatException(
          'The update is not signed by the Hopboard maintainer. Nothing was installed.',
        );
      }
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map;
      final signedHash = manifest['sha256'];
      if (manifest['version'] != version ||
          manifest['filename'] != filename ||
          manifest['size'] != expectedSize ||
          signedHash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(signedHash)) {
        throw const FormatException('Invalid update manifest.');
      }
      final base = directory != null
          ? await directory!()
          : Directory(
              (await _channel.invokeMethod<String>('updateDirectory'))!,
            );
      await base.create(recursive: true);
      folder = await base.createTemp('download-');
      final file = File('${folder.path}/$filename');
      final sink = _DigestSink();
      final hash = sha256.startChunkedConversion(sink);
      final output = await file.open(mode: FileMode.writeOnly);
      var size = 0;
      try {
        await for (final bytes in _request(address(installer))) {
          size += bytes.length;
          if (size > expectedSize) {
            throw const FormatException('Installer size does not match.');
          }
          hash.add(bytes);
          await output.writeFrom(bytes);
          progress?.call(size / expectedSize);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      hash.close();
      final digest = sink.digest!.toString();
      if (size != expectedSize || digest != signedHash) {
        throw const FormatException(
          'Installer verification failed. Nothing was installed.',
        );
      }
      return PreparedUpdate(version, file, digest);
    } on SocketException {
      if (folder != null && await folder.exists()) {
        await folder.delete(recursive: true);
      }
      throw SessionException('Connect to the internet to download the update.');
    } catch (_) {
      if (folder != null && await folder.exists()) {
        await folder.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> install(PreparedUpdate update) => _channel.invokeMethod<void>(
    'installUpdate',
    {'path': update.file.absolute.path, 'sha256': update.hash},
  );
}
