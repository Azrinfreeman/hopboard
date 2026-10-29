import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'protocol.dart';

abstract class Vault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryVault implements Vault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String certificateFingerprint(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

class Identity {
  Identity(this.id, this.certificate, this.privateKey);
  final String id;
  final String certificate;
  final String privateKey;

  String get fingerprint {
    final pem = certificate.replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
    return sha256.convert(base64.decode(pem)).toString();
  }

  SecurityContext context() => SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  static Future<Identity> load(Vault vault) async {
    final stored = await vault.read('identity.v1');
    if (stored != null) {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return Identity(
        field(json, 'id'),
        field(json, 'certificate', max: 20000),
        field(json, 'privateKey', max: 20000),
      );
    }
    final identity = await Isolate.run(generate);
    await vault.write(
      'identity.v1',
      jsonEncode({
        'id': identity.id,
        'certificate': identity.certificate,
        'privateKey': identity.privateKey,
      }),
    );
    return identity;
  }

  static Identity generate() {
    final id = randomSecret(16);
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'LocalClipboard-$id'},
      privateKey,
      publicKey,
      signingAlgorithm: 'SHA-256',
    );
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      notBefore: DateTime.now().subtract(const Duration(days: 1)),
      serialNumber: BigInt.parse(
        sha256.convert(utf8.encode(id)).toString().substring(0, 30),
        radix: 16,
      ).toString(),
    );
    return Identity(
      id,
      certificate,
      CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    );
  }
}

class SavedHost {
  SavedHost({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.fingerprint,
    required this.credential,
  });
  final String id;
  final String name;
  String address;
  int port;
  final String fingerprint;
  final String credential;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'port': port,
    'fingerprint': fingerprint,
    'credential': credential,
  };
  factory SavedHost.fromJson(Map<String, dynamic> json) => SavedHost(
    id: field(json, 'id'),
    name: field(json, 'name', max: 64),
    address: field(json, 'address'),
    port: json['port'] as int,
    fingerprint: field(json, 'fingerprint'),
    credential: field(json, 'credential'),
  );
}

class TrustedDevice {
  TrustedDevice(this.id, this.name, this.credentialHash);
  final String id;
  final String name;
  final String credentialHash;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'hash': credentialHash,
  };
}

class TrustStore {
  TrustStore(this.vault);
  final Vault vault;
  final hosts = <String, SavedHost>{};
  final devices = <String, TrustedDevice>{};
  Future<void> _writes = Future.value();

  Future<void> load() async {
    final stored = await vault.read('trust.v1');
    if (stored == null) return;
    final json = jsonDecode(stored) as Map<String, dynamic>;
    for (final data in json['hosts'] as List) {
      final host = SavedHost.fromJson(Map<String, dynamic>.from(data as Map));
      hosts[host.id] = host;
    }
    for (final data in json['devices'] as List) {
      final d = Map<String, dynamic>.from(data as Map);
      final device = TrustedDevice(
        field(d, 'id'),
        field(d, 'name', max: 64),
        field(d, 'hash'),
      );
      devices[device.id] = device;
    }
  }

  Future<void> save() {
    final snapshot = jsonEncode({
      'hosts': hosts.values.map((h) => h.toJson()).toList(),
      'devices': devices.values.map((d) => d.toJson()).toList(),
    });
    final result = _writes.then((_) => vault.write('trust.v1', snapshot));
    _writes = result.catchError((Object _) {});
    return result;
  }
}

Future<SecureSocket> connectPinned(String address, int port, String pin) async {
  if (!isLocalAddress(address)) {
    throw SessionException(
      'This app connects only to local IPv4 addresses.',
      'address',
    );
  }
  final context = SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
  var rejectedPin = false;
  late SecureSocket socket;
  try {
    socket = await SecureSocket.connect(
      address,
      port,
      context: context,
      timeout: const Duration(seconds: 5),
      onBadCertificate: (cert) {
        final matches = certificateFingerprint(cert) == pin;
        rejectedPin = !matches;
        return matches;
      },
    );
  } on HandshakeException {
    if (rejectedPin) {
      throw SessionException(
        'Host identity changed. Pair again only if you trust this device.',
        'certificate',
      );
    }
    rethrow;
  }
  final cert = socket.peerCertificate;
  if (cert == null || certificateFingerprint(cert) != pin) {
    socket.destroy();
    throw SessionException(
      'Host identity changed. Pair again only if you trust this device.',
      'certificate',
    );
  }
  return socket;
}
