import 'package:flutter/services.dart';

import '../core/identity.dart';

class SecureVault implements Vault {
  static const _channel = MethodChannel('dev.localclipboard/native');
  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('secureRead', {'key': key});
  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('secureWrite', {'key': key, 'value': value});
  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('secureDelete', {'key': key});
}
