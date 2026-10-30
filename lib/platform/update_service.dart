import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  UpdateService({this.fetch, this.directory});
  // Injection keeps updater tests entirely offline.
  final Stream<List<int>> Function(Uri)? fetch;
  final Future<Directory> Function()? directory;
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
      final checksum = utf8
          .decode(await _small(address(asset('$filename.sha256')), 4096))
          .trim();
      final match = RegExp(r'^([0-9a-fA-F]{64})(?:\s+\*?([^\r\n]+))?$')
          .firstMatch(checksum);
      if (match == null || match[2] != null && match[2] != filename) {
        throw const FormatException('Invalid installer checksum.');
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
      if (size != expectedSize || digest != match[1]!.toLowerCase()) {
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
