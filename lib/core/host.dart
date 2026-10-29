import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'framing.dart';
import 'identity.dart';
import 'pair_code.dart';
import 'protocol.dart';
import 'session_engine.dart';

class PairRequest {
  PairRequest(this.id, this.name, {this.address, this.replaces});
  final String id;
  final String name;

  /// The requesting device's local IP address, to help the user recognise it.
  final String? address;

  /// Name of the trusted device whose pairing this request would replace.
  final String? replaces;
  final _decision = Completer<bool>();
  Future<bool> get decision => _decision.future;
  void decide(bool accept) {
    if (!_decision.isCompleted) _decision.complete(accept);
  }
}

class _Peer {
  _Peer(this.connection, this.address, this.lastSeen);
  final FramedConnection connection;
  final String address;
  Duration lastSeen;
  String? id;
  bool pairing = false;
  PairCodeServer? codePair;
  Timer? authenticationTimer;
}

class LocalHost {
  LocalHost(this.identity, this.trust, this.name);
  final Identity identity;
  final TrustStore trust;
  final String name;
  final engine = SessionEngine();
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final pairing = StreamController<PairRequest>.broadcast();
  final _peers = <_Peer>{};
  final _clock = Stopwatch()..start();
  final _receipts = <String, String>{};
  SecureServerSocket? _server;
  Timer? _heartbeat;
  Timer? _expiry;
  String? _invite;
  Duration _inviteDeadline = Duration.zero;
  PairRequest? _pending;
  PairCodeWindow? _codeWindow;
  bool _stopped = false;
  String? address;
  // Cached: a failed rebind leaves _server closed, but the port is still ours.
  int _port = 0;
  int get port => _port;

  Future<void> start(String interface, [int port = defaultPort]) async {
    address = interface;
    engine.onChange = () {
      _receipts.clear();
      _expiry?.cancel();
      if (engine.item != null) {
        _expiry = Timer(engine.item!.remaining, engine.clear);
      }
      _broadcast(engine.snapshot());
      _members();
    };
    _server = await SecureServerSocket.bind(
      interface,
      port,
      identity.context(),
      backlog: 16,
      requestClientCertificate: false,
    );
    _port = _server!.port;
    _server!.listen(
      _accept,
      onError: (Object error) {
        if (!_stopped && error is! HandshakeException) {
          events.add({'type': 'hostError'});
        }
      },
    );
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      for (final peer in _peers.toList()) {
        if (_clock.elapsed - peer.lastSeen > const Duration(seconds: 65)) {
          peer.connection.close();
        } else {
          peer.connection.post({'type': 'ping'});
        }
      }
    });
  }

  Invitation invite() {
    _pending?.decide(false);
    _invite = randomSecret();
    _codeWindow = PairCodeWindow(identity.id, identity.fingerprint);
    _inviteDeadline = _clock.elapsed + const Duration(minutes: 2);
    return Invitation(
      hostId: identity.id,
      address: address!,
      port: port,
      fingerprint: identity.fingerprint,
      secret: _invite!,
    );
  }

  Duration get inviteRemaining =>
      _invite == null ? Duration.zero : _inviteDeadline - _clock.elapsed;
  String? get pairCode =>
      inviteRemaining > Duration.zero ? _codeWindow?.code : null;
  bool get codeExhausted => _codeWindow?.exhausted ?? false;

  Future<void> rebind(String interface) async {
    cancelInvite();
    final previousPort = port;
    await _server?.close();
    for (final peer in _peers.toList()) {
      peer.connection.close();
    }
    _server = await SecureServerSocket.bind(
      interface,
      previousPort,
      identity.context(),
      backlog: 16,
    );
    _port = _server!.port;
    address = interface;
    _server!.listen(
      _accept,
      onError: (Object error) {
        if (!_stopped && error is! HandshakeException) {
          events.add({'type': 'hostError'});
        }
      },
    );
  }

  void cancelInvite() {
    _invite = null;
    _codeWindow = null;
    _pending?.decide(false);
  }

  void _accept(SecureSocket socket) {
    final address = socket.remoteAddress.address;
    // Separate budgets keep unauthenticated sockets, especially from one
    // address, from occupying the slots trusted devices need to reconnect.
    final unauthenticated = _peers.where((p) => p.id == null);
    if (_stopped ||
        _peers.length >= 16 ||
        !isLocalAddress(address) ||
        unauthenticated.length >= 8 ||
        unauthenticated.where((p) => p.address == address).length >= 3) {
      socket.destroy();
      return;
    }
    final peer = _Peer(FramedConnection(socket), address, _clock.elapsed);
    _peers.add(peer);
    peer.authenticationTimer = Timer(const Duration(seconds: 5), () {
      if (peer.id == null && !peer.pairing) peer.connection.close();
    });
    peer.connection.messages.listen(
      (message) {
        peer.lastSeen = _clock.elapsed;
        unawaited(
          _handle(peer, message).catchError((Object _) {
            peer.connection.close();
          }),
        );
      },
      onDone: () {
        peer.authenticationTimer?.cancel();
        _peers.remove(peer);
        if (!_stopped) _members();
      },
    );
  }

  Future<void> _handle(_Peer peer, Map<String, dynamic> message) async {
    try {
      if (peer.id == null) {
        if (peer.pairing) {
          peer.connection.close();
          return;
        }
        if (message['type'] == 'codeStart' ||
            message['type'] == 'codeProof' ||
            message['type'] == 'codeConfirm') {
          await _codePair(peer, message);
          return;
        }
        if (peer.codePair != null) {
          peer.connection.close();
          return;
        }
        if (message['type'] == 'pair') {
          await _pair(peer, message);
          return;
        }
        if (message['type'] != 'auth') {
          throw SessionException('Pair this device first.', 'unauthorized');
        }
        final id = field(message, 'deviceId');
        final credential = field(message, 'credential');
        final device = trust.devices[id];
        if (device == null ||
            device.credentialHash !=
                sha256.convert(utf8.encode(credential)).toString()) {
          throw SessionException(
            'Device access was revoked or is unknown.',
            'unauthorized',
          );
        }
        if (_peers.where((p) => p.id != null && p.id != id).length >= 7) {
          throw SessionException('This session is full.', 'full');
        }
        for (final other in _peers.where((p) => p.id == id).toList()) {
          other.connection.close();
        }
        peer.id = id;
        peer.authenticationTimer?.cancel();
        peer.connection.post({
          'type': 'hello',
          'epoch': engine.epoch,
          'hostId': identity.id,
          'hostName': name,
        });
        peer.connection.post(engine.snapshot());
        _members();
        return;
      }
      final id = peer.id!;
      switch (message['type']) {
        case 'publish':
          final ack = engine.publish(id, trust.devices[id]!.name, message);
          peer.connection.post(ack);
        case 'receipt':
          receipt(id, message);
        case 'ping':
          peer.connection.post({'type': 'pong'});
        case 'pong':
          break;
        default:
          throw SessionException('Unsupported message.', 'protocol');
      }
    } on SessionException catch (error) {
      peer.connection.post({
        'type': 'error',
        'code': error.code,
        'message': error.message,
        'requestId': message['requestId'],
      });
      if (error.code == 'conflict') peer.connection.post(engine.snapshot());
      if (peer.id == null) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        peer.connection.close();
      }
    } on FormatException {
      peer.connection.close();
    }
  }

  Future<void> _codePair(_Peer peer, Map<String, dynamic> message) async {
    final window = _codeWindow;
    if (_invite == null || window == null || inviteRemaining <= Duration.zero) {
      throw SessionException(
        'Invitation expired or used. Create a new one.',
        'invite',
      );
    }
    if (message['type'] == 'codeStart') {
      if (peer.codePair != null) {
        throw const FormatException('Pairing already started.');
      }
      final nonce = field(message, 'nonce', max: 43);
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce)) {
        throw const FormatException('Invalid pairing nonce.');
      }
      final exchange = window.start(nonce, source: peer.address);
      peer.codePair = exchange;
      peer.authenticationTimer?.cancel();
      peer.authenticationTimer = Timer(const Duration(seconds: 10), () {
        if (peer.id == null && !peer.pairing) peer.connection.close();
      });
      peer.connection.post(exchange.challenge());
      return;
    }
    final exchange = peer.codePair;
    if (exchange == null || exchange.window != window) {
      throw SessionException(
        'Invitation changed. Enter the new code.',
        'invite',
      );
    }
    if (message['type'] == 'codeProof') {
      peer.connection.post(exchange.prove(message));
      return;
    }
    exchange.confirm(message);
    // No invite secret or saved credential is exposed until the client has
    // authenticated this socket's certificate and confirmed the binding.
    await _pair(peer, {
      'deviceId': field(message, 'deviceId'),
      'name': field(message, 'name', max: 64),
      'invite': _invite,
    });
  }

  Future<void> _pair(_Peer peer, Map<String, dynamic> message) async {
    if (_invite == null ||
        inviteRemaining <= Duration.zero ||
        message['invite'] != _invite ||
        _pending != null) {
      throw SessionException(
        'Invitation expired, used, or busy. Create a new one.',
        'invite',
      );
    }
    final id = field(message, 'deviceId');
    if (id == identity.id ||
        trust.devices.length >= 7 && !trust.devices.containsKey(id)) {
      throw SessionException(
        'Remove a trusted device before adding another.',
        'full',
      );
    }
    peer.pairing = true;
    final request = PairRequest(
      id,
      field(message, 'name', max: 64),
      address: peer.address,
      replaces: trust.devices[id]?.name,
    );
    _pending = request;
    pairing.add(request);
    peer.connection.post({'type': 'pending'});
    final accepted = await request.decision.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        request.decide(false);
        return false;
      },
    );
    if (_pending == request) _pending = null;
    if (!accepted ||
        _stopped ||
        peer.connection.closed ||
        inviteRemaining <= Duration.zero ||
        message['invite'] != _invite) {
      throw SessionException('Pairing was declined or timed out.', 'declined');
    }
    _invite = null;
    _codeWindow = null;
    final credential = randomSecret();
    final previous = trust.devices[id];
    void restore() {
      if (previous == null) {
        trust.devices.remove(id);
      } else {
        trust.devices[id] = previous;
      }
    }

    trust.devices[id] = TrustedDevice(
      id,
      request.name,
      sha256.convert(utf8.encode(credential)).toString(),
    );
    try {
      await trust.save();
    } catch (_) {
      restore();
      throw SessionException('Could not securely save this device.', 'storage');
    }
    try {
      await peer.connection.send({
        'type': 'paired',
        'credential': credential,
        'hostId': identity.id,
        'hostName': name,
      });
    } catch (_) {
      // The device never received its credential; don't leave a dead slot.
      restore();
      await trust.save().catchError((Object _) {});
      rethrow;
    }
    peer.connection.close();
    // A re-paired device's older sessions used the replaced credential.
    for (final other in _peers.where((p) => p.id == id).toList()) {
      other.connection.close();
    }
    _members();
  }

  Map<String, dynamic> publish(Map<String, dynamic> message) =>
      engine.publish(identity.id, name, message);

  void receipt(String id, Map<String, dynamic> message) {
    if (message['itemId'] != engine.item?.id) return;
    const statuses = {
      'available',
      'applied',
      'needsAction',
      'failed',
      'paused',
    };
    if (!statuses.contains(message['status'])) return;
    _receipts[id] = message['status'] as String;
    _members();
  }

  void _members() {
    _broadcast({
      'type': 'members',
      'devices': [
        {
          'id': identity.id,
          'name': name,
          'host': true,
          'online': true,
          'status': _receipts[identity.id] ?? 'available',
        },
        for (final device in trust.devices.values)
          {
            'id': device.id,
            'name': device.name,
            'host': false,
            'online': _peers.any(
              (p) => p.id == device.id && !p.connection.closed,
            ),
            'status': _receipts[device.id] ?? 'available',
          },
      ],
    });
  }

  void _broadcast(Map<String, dynamic> message) {
    if (_stopped) return;
    events.add(message);
    for (final peer in _peers.where((p) => p.id != null).toList()) {
      peer.connection.post(message);
    }
  }

  Future<void> revoke(String id) async {
    final old = trust.devices.remove(id);
    try {
      await trust.save();
    } catch (_) {
      if (old != null) trust.devices[id] = old;
      rethrow;
    }
    for (final peer in _peers.where((p) => p.id == id).toList()) {
      peer.connection.post({
        'type': 'error',
        'code': 'unauthorized',
        'message': 'This device was removed by the host.',
      });
      peer.connection.close();
    }
    engine.forget(id);
    _receipts.remove(id);
    _members();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    cancelInvite();
    _heartbeat?.cancel();
    _expiry?.cancel();
    for (final peer in _peers.toList()) {
      peer.connection.close();
    }
    await _server?.close();
    await events.close();
    await pairing.close();
    engine.item = null;
  }
}
