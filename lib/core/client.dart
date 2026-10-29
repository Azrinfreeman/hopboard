import 'dart:async';
import 'dart:io';

import 'framing.dart';
import 'identity.dart';
import 'pair_code.dart';
import 'protocol.dart';

class SessionClient {
  /// [address] and [port] override the saved route, e.g. an unverified
  /// discovery result; the saved certificate pin is always enforced.
  SessionClient(this.identity, this.host, {String? address, int? port})
    : address = address ?? host.address,
      port = port ?? host.port;
  final Identity identity;
  final SavedHost host;
  final String address;
  final int port;
  final events = StreamController<Map<String, dynamic>>.broadcast();
  FramedConnection? _connection;
  Timer? _heartbeat;
  Stopwatch _lastSeen = Stopwatch()..start();
  bool _stopped = false;

  static Future<SavedHost> pairWithCode(
    Identity identity,
    String name,
    String address,
    int port,
    String code, {
    void Function()? onPending,
  }) async {
    final normalized = normalizePairCode(code);
    if (!isLocalAddress(address) || port < 1 || port > 65535) {
      throw SessionException(
        'Use the local IPv4 address shown on the host.',
        'address',
      );
    }
    // This bootstrap socket is quarantined: only PAKE messages may travel
    // until the code authenticates the exact certificate of this socket.
    final socket = await SecureSocket.connect(
      address,
      port,
      context: SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2,
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 5),
    );
    final cert = socket.peerCertificate;
    if (cert == null) {
      socket.destroy();
      throw SessionException('Host certificate unavailable.', 'certificate');
    }
    final fingerprint = certificateFingerprint(cert);
    final exchange = PairCodeClient(normalized, fingerprint);
    final connection = FramedConnection(socket);
    final result = Completer<SavedHost>();
    var stage = 0;
    final sub = connection.messages.listen(
      (message) {
        try {
          if (message['type'] == 'error') {
            throw SessionException(
              field(message, 'message', max: 512),
              field(message, 'code'),
            );
          }
          if (stage == 0 && message['type'] == 'codeChallenge') {
            final proof = exchange.prove(message);
            if (exchange.hostId == identity.id) {
              throw SessionException('Choose another device to join.');
            }
            stage = 1;
            connection.post(proof);
          } else if (stage == 1 && message['type'] == 'codeVerified') {
            final confirmation = exchange.confirm(message);
            stage = 2;
            connection.post({
              ...confirmation,
              'deviceId': identity.id,
              'name': name,
            });
          } else if (stage == 2 && message['type'] == 'pending') {
            stage = 3;
            onPending?.call();
          } else if (stage == 3 && message['type'] == 'paired') {
            if (message['hostId'] != exchange.hostId) {
              throw SessionException(
                'Host identity does not match.',
                'certificate',
              );
            }
            stage = 4;
            result.complete(
              SavedHost(
                id: exchange.hostId,
                name: field(message, 'hostName', max: 64),
                address: address,
                port: port,
                fingerprint: fingerprint,
                credential: field(message, 'credential'),
              ),
            );
          } else {
            throw SessionException('Unexpected pairing response.', 'code');
          }
        } catch (error) {
          if (!result.isCompleted) result.completeError(error);
          connection.close();
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            SessionException(
              'Code pairing closed. Check the code or create a new one.',
              'code',
            ),
          );
        }
      },
    );
    try {
      await connection.send({'type': 'codeStart', 'nonce': exchange.nonce});
      return await result.future.timeout(const Duration(seconds: 60));
    } finally {
      await sub.cancel();
      connection.close();
    }
  }

  static Future<SavedHost> pair(
    Identity identity,
    String name,
    Invitation invite, {
    void Function()? onPending,
  }) async {
    final connection = FramedConnection(
      await connectPinned(invite.address, invite.port, invite.fingerprint),
    );
    final result = Completer<SavedHost>();
    final sub = connection.messages.listen(
      (message) {
        try {
          switch (message['type']) {
            case 'pending':
              onPending?.call();
            case 'paired':
              if (message['hostId'] != invite.hostId) {
                throw SessionException(
                  'Host identity does not match invitation.',
                  'certificate',
                );
              }
              if (!result.isCompleted) {
                result.complete(
                  SavedHost(
                    id: invite.hostId,
                    name: field(message, 'hostName', max: 64),
                    address: invite.address,
                    port: invite.port,
                    fingerprint: invite.fingerprint,
                    credential: field(message, 'credential'),
                  ),
                );
              }
            case 'error':
              throw SessionException(
                field(message, 'message', max: 512),
                field(message, 'code'),
              );
          }
        } catch (error) {
          if (!result.isCompleted) result.completeError(error);
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(SessionException('Pairing connection closed.'));
        }
      },
    );
    try {
      await connection.send({
        'type': 'pair',
        'deviceId': identity.id,
        'name': name,
        'invite': invite.secret,
      });
      return await result.future.timeout(const Duration(seconds: 50));
    } finally {
      await sub.cancel();
      connection.close();
    }
  }

  Future<void> connect() async {
    if (_stopped) throw SessionException('Connection cancelled.');
    final connection = FramedConnection(
      await connectPinned(address, port, host.fingerprint),
    );
    if (_stopped) {
      connection.close();
      return;
    }
    _connection = connection;
    _lastSeen = Stopwatch()..start();
    final hello = Completer<void>();
    connection.messages.listen(
      (message) {
        _lastSeen.reset();
        if (message['type'] == 'ping') {
          connection.post({'type': 'pong'});
          return;
        }
        if (message['type'] == 'hello') {
          if (message['hostId'] != host.id) {
            connection.close();
            return;
          }
          if (!hello.isCompleted) hello.complete();
        }
        if (message['type'] == 'error' && !hello.isCompleted) {
          hello.completeError(
            SessionException(
              field(message, 'message', max: 512),
              field(message, 'code'),
            ),
          );
        }
        if (!_stopped) events.add(message);
      },
      onDone: () {
        _heartbeat?.cancel();
        if (!hello.isCompleted) {
          hello.completeError(SessionException('Host closed the connection.'));
        }
        if (!_stopped) events.add({'type': 'disconnected'});
      },
    );
    await connection.send({
      'type': 'auth',
      'deviceId': identity.id,
      'credential': host.credential,
    });
    await hello.future.timeout(const Duration(seconds: 5));
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_lastSeen.elapsed > const Duration(seconds: 65)) {
        connection.close();
      } else {
        connection.post({'type': 'ping'});
      }
    });
  }

  Future<void> send(Map<String, dynamic> message) {
    final connection = _connection;
    if (connection == null || connection.closed) {
      return Future.error(
        SessionException('Waiting for the host to reconnect.'),
      );
    }
    return connection.send(message);
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _heartbeat?.cancel();
    _connection?.close();
    unawaited(events.close());
  }
}
