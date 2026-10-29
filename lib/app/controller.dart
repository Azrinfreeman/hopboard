import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/client.dart';
import '../core/host.dart';
import '../core/identity.dart';
import '../core/pair_code.dart';
import '../core/protocol.dart';
import '../platform/clipboard_bridge.dart';
import '../platform/discovery.dart';
import '../platform/secure_vault.dart';

/// Stored identity or trust could not be read, e.g. after a password reset
/// made DPAPI data unreadable or the Android Keystore key was invalidated.
class StorageFailure implements Exception {
  StorageFailure(this.cause);
  final Object cause;
  @override
  String toString() => 'Secure storage is unavailable: $cause';
}

class _Publication {
  _Publication(this.message, this.automatic, this.revision);
  final Map<String, dynamic> message;
  final bool automatic;
  final int? revision;
  final age = Stopwatch()..start();
}

class AppController extends ChangeNotifier {
  AppController({
    required this.identity,
    required this.trust,
    required this.clipboard,
    required this.discovery,
    required this.preferences,
  });
  final Identity identity;
  final TrustStore trust;
  final ClipboardBridge clipboard;
  final LanDiscovery discovery;
  final SharedPreferences preferences;

  String name = 'My device';
  String status = 'Ready to connect';
  String? error;
  bool busy = false;
  bool connected = false;
  bool automatic = false;
  bool paused = false;
  bool keepScreenAwake = false;
  bool foreground = true;
  bool _disposed = false;
  bool _connecting = false;
  bool _awaitingSnapshot = true;
  bool _resumeGuard = true;
  bool _localDirty = false;
  bool _clipboardReading = false;
  bool _clipboardReadAgain = false;
  bool _rebindBusy = false;
  int _revision = 0;
  int? _observedRevision;
  String? _localPublicationItemId;
  int? _localPublicationRevision;
  int _connectionGeneration = 0;
  int _attempt = 0;
  String? _epoch;
  int _sequence = 0;
  int _displaySequence = -1;
  String? _displayEpoch;
  String? _lastHostId;
  String? _interfaceName;
  LocalHost? host;
  SessionClient? _client;
  SavedHost? selectedHost;
  Invitation? invitation;
  PairRequest? pendingPair;
  ClipItem? item;
  String itemStatus = 'No text shared yet';
  String? conflictText;
  List<Map<String, dynamic>> members = [];
  List<LanInterface> interfaces = [];
  StreamSubscription<Map<String, dynamic>>? _sessionSub;
  StreamSubscription<PairRequest>? _pairSub;
  StreamSubscription<void>? _clipboardSub;
  StreamSubscription<String>? _actionSub;
  Timer? _reconnect;
  Timer? _coalesce;
  Timer? _retry;
  Timer? _expire;
  Timer? _networkTimer;
  _Publication? _pending;
  ClipboardSnapshot? _candidate;
  Future<void> _application = Future.value();

  bool get hosting => host != null;
  bool get sharing => connected && !paused && foreground;
  bool get sending => _pending != null;
  bool get mobile => Platform.isIOS || Platform.isAndroid;
  bool get canAutomatic => clipboard.supportsAutomatic;

  static Future<AppController> load() async {
    final vault = SecureVault();
    final Identity identity;
    final TrustStore trust;
    try {
      identity = await Identity.load(vault);
      trust = TrustStore(vault);
      await trust.load();
    } catch (error) {
      throw StorageFailure(error);
    }
    final controller = AppController(
      identity: identity,
      trust: trust,
      clipboard: ClipboardBridge(),
      discovery: LanDiscovery(),
      preferences: await SharedPreferences.getInstance(),
    );
    await controller.initialize();
    return controller;
  }

  /// Deletes this device's identity and every pairing so the app can start
  /// fresh. Other devices must forget this one and pair again.
  static Future<void> resetStorage() async {
    final vault = SecureVault();
    try {
      await vault.delete('trust.v1');
      await vault.delete('identity.v1');
    } catch (error) {
      // Keep offering the reset if deletion itself failed.
      throw StorageFailure(error);
    }
    await (await SharedPreferences.getInstance()).remove('lastHost');
  }

  Future<void> initialize({
    bool discover = true,
    bool loadInterfaces = true,
  }) async {
    name =
        preferences.getString('deviceName') ??
        (Platform.isWindows
            ? 'Windows PC'
            : Platform.isIOS
            ? 'iPhone'
            : 'Android phone');
    automatic = canAutomatic && (preferences.getBool('automatic') ?? false);
    _lastHostId = preferences.getString('lastHost');
    await clipboard.initialize();
    _clipboardSub = clipboard.changes.stream.listen((_) {
      // Native compare-and-set protects writes until this event is classified.
      unawaited(_clipboardChanged());
    });
    _actionSub = clipboard.actions.stream.listen((action) {
      if (action == 'pause') {
        unawaited(setPaused(!paused));
      } else if (action == 'quit') {
        unawaited(quit());
      } else if (action == 'networkChanged') {
        networkChanged();
      } else if (action.startsWith('pasted:')) {
        unawaited(
          sendText(action.substring(7)).catchError((Object e) {
            showError(e);
          }),
        );
      }
    });
    discovery.onChange = () {
      final saved = selectedHost;
      final nearby = saved == null ? null : discovery.hosts[saved.id];
      if (saved != null && nearby != null && !connected && !_connecting) {
        unawaited(_connect());
      }
      _notify();
    };
    if (loadInterfaces) {
      try {
        interfaces = await LanInterface.list();
      } catch (_) {}
    }
    if (discover) {
      try {
        await discovery.start();
      } catch (_) {
        status = 'Discovery unavailable · QR and manual join still work';
      }
    }
    final lastHost = trust.hosts[_lastHostId];
    if (lastHost != null) {
      unawaited(
        joinSaved(lastHost).catchError((Object failure) {
          showError(failure);
        }),
      );
    }
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    unawaited(clipboard.updateTray(paused, status).catchError((Object _) {}));
  }

  void showError(Object failure) {
    error = failure is SessionException
        ? failure.message
        : failure is FormatException
        ? failure.message.toString()
        : failure is SocketException
        ? 'Could not reach the device. Check Wi-Fi, local-network permission, and the Private-network firewall rule.'
        : 'The operation could not finish. Please try again.';
    _notify();
  }

  void dismissError() {
    error = null;
    _notify();
  }

  Future<void> rename(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 64) {
      throw const FormatException('Use a device name of 1–64 characters.');
    }
    if (hosting || selectedHost != null) {
      throw SessionException(
        'Leave the current session before renaming this device.',
      );
    }
    name = trimmed;
    await preferences.setString('deviceName', name);
    _notify();
  }

  Future<void> startHost(
    LanInterface interface, {
    int port = defaultPort,
  }) async {
    if (busy) return;
    await _networkAccess();
    busy = true;
    _notify();
    try {
      await leave();
      final localHost = LocalHost(identity, trust, name);
      await localHost.start(interface.address, port);
      host = localHost;
      _interfaceName = interface.name;
      _epoch = localHost.engine.epoch;
      _sequence = localHost.engine.sequence;
      _displaySequence = -1;
      _displayEpoch = _epoch;
      _awaitingSnapshot = false;
      connected = true;
      status = 'Hosting on ${interface.address}';
      _sessionSub = localHost.events.stream.listen(_message);
      _pairSub = localHost.pairing.stream.listen((request) {
        pendingPair = request;
        _notify();
        unawaited(
          request.decision.whenComplete(() {
            if (pendingPair == request) pendingPair = null;
            _notify();
          }),
        );
      });
      await _baseline();
      _message(localHost.engine.snapshot());
      try {
        await discovery.advertise(
          identity.id,
          name,
          interface.address,
          localHost.port,
        );
      } catch (_) {
        status = 'Hosting · discovery unavailable, use QR pairing';
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  void newInvitation() {
    final localHost = host;
    if (localHost == null) return;
    invitation = localHost.invite();
    _notify();
  }

  void closeInvitation() {
    host?.cancelInvite();
    invitation = null;
    _notify();
  }

  Future<void> pair(String encoded) async {
    if (busy) return;
    await _networkAccess();
    final invite = Invitation.parse(encoded.trim());
    if (invite.hostId == identity.id) {
      throw SessionException('Choose another device to join.');
    }
    busy = true;
    status = 'Connecting securely…';
    _notify();
    try {
      await leave();
      final saved = await SessionClient.pair(
        identity,
        name,
        invite,
        onPending: () {
          status = 'Waiting for approval on the host';
          _notify();
        },
      );
      await _savePairing(saved);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> pairWithCode(String code, String address, int port) async {
    if (busy) return;
    final normalized = normalizePairCode(code);
    await _networkAccess();
    busy = true;
    status = 'Verifying pairing code…';
    _notify();
    try {
      await leave();
      final saved = await SessionClient.pairWithCode(
        identity,
        name,
        address,
        port,
        normalized,
        onPending: () {
          status = 'Waiting for approval on the host';
          _notify();
        },
      );
      await _savePairing(saved);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _savePairing(SavedHost saved) async {
    trust.hosts[saved.id] = saved;
    try {
      await trust.save();
    } catch (_) {
      trust.hosts.remove(saved.id);
      throw SessionException(
        'Could not securely save pairing. Create a fresh invitation and try again.',
      );
    }
    await joinSaved(saved);
  }

  Future<void> joinSaved(SavedHost saved) async {
    await _networkAccess();
    await leave();
    selectedHost = saved;
    _lastHostId = saved.id;
    await preferences.setString('lastHost', saved.id);
    await _connect();
  }

  Future<void> _networkAccess() async {
    await clipboard.ensureNetworkAccess();
    // Retry discovery after a previously denied LAN permission is granted.
    try {
      await discovery.start();
    } catch (_) {}
  }

  Future<void> _connect() async {
    final saved = selectedHost;
    if (saved == null || _connecting || !foreground || _disposed) return;
    _connecting = true;
    final generation = ++_connectionGeneration;
    _reconnect?.cancel();
    connected = false;
    status = _attempt == 0
        ? 'Connecting to ${saved.name}…'
        : 'Reconnecting to ${saved.name}…';
    _notify();
    // Discovery is unauthenticated: anyone can advertise this host's id. Try
    // an advertised route first, but adopt it only once the pin matches.
    final nearby = discovery.hosts[saved.id];
    final routes = <(String, int)>[
      if (nearby != null &&
          (nearby.address != saved.address || nearby.port != saved.port))
        (nearby.address, nearby.port),
      (saved.address, saved.port),
    ];
    try {
      await _baseline();
      Object? failure;
      for (final (address, port) in routes) {
        _client?.stop();
        await _sessionSub?.cancel();
        if (generation != _connectionGeneration) return;
        final client = SessionClient(
          identity,
          saved,
          address: address,
          port: port,
        );
        _client = client;
        _awaitingSnapshot = true;
        _sessionSub = client.events.stream.listen((message) {
          if (generation == _connectionGeneration) _message(message);
        });
        try {
          await client.connect();
        } catch (error) {
          client.stop();
          if (generation != _connectionGeneration) return;
          failure = error;
          // Credentials are refused by the real host; no other route helps.
          if (error is SessionException && error.code == 'unauthorized') {
            break;
          }
          continue;
        }
        if (generation != _connectionGeneration || !foreground) {
          client.stop();
          return;
        }
        saved.address = address;
        saved.port = port;
        connected = true;
        _attempt = 0;
        status = 'Connected to ${saved.name}';
        unawaited(trust.save().catchError((Object _) {}));
        return;
      }
      if (failure is SessionException &&
          {'unauthorized', 'address'}.contains(failure.code)) {
        selectedHost = null;
        await preferences.remove('lastHost');
        status = 'Connection needs attention';
        showError(failure);
      } else if (failure is SessionException &&
          failure.code == 'certificate') {
        // A reassigned address or a spoofer answers with another certificate.
        // Keep the pairing and retry; discovery may find the real host.
        status = 'Host identity did not match · retrying';
        showError(failure);
        _scheduleReconnect();
      } else {
        status = failure is SessionException && failure.code == 'full'
            ? 'Session is full · retrying automatically'
            : 'Host unavailable · retrying automatically';
        _scheduleReconnect();
      }
    } finally {
      if (generation == _connectionGeneration) _connecting = false;
      _notify();
    }
  }

  void _scheduleReconnect() {
    if (selectedHost == null || !foreground || _disposed) return;
    _reconnect?.cancel();
    const seconds = [1, 2, 4, 8, 15];
    final delay = seconds[_attempt.clamp(0, seconds.length - 1)];
    _attempt++;
    _reconnect = Timer(
      Duration(milliseconds: delay * 1000 + Random().nextInt(250)),
      () => unawaited(_connect()),
    );
  }

  Future<void> _baseline() async {
    if (!canAutomatic || !foreground) {
      _resumeGuard = true;
      return;
    }
    try {
      final snapshot = await clipboard.read();
      _resumeGuard =
          _localDirty ||
          (_observedRevision == null
              ? snapshot.text?.isNotEmpty == true
              : snapshot.revision != _observedRevision);
      _observedRevision = snapshot.revision;
    } catch (_) {
      _resumeGuard = true;
    }
  }

  void _message(Map<String, dynamic> message) {
    if (_disposed) return;
    try {
      switch (message['type']) {
        case 'hello':
          final epoch = field(message, 'epoch');
          if (_epoch != null && epoch != _epoch) {
            _cancelPublication(
              'The host restarted. Send again to share current text.',
            );
          }
          _epoch = epoch;
        case 'state':
          final epoch = field(message, 'epoch');
          final sequence = message['seq'];
          if (sequence is! int || sequence < 0) {
            throw const FormatException('Invalid sequence.');
          }
          final initial = _awaitingSnapshot;
          _awaitingSnapshot = false;
          _epoch = epoch;
          _sequence = sequence;
          if (_displayEpoch == epoch &&
              sequence <= _displaySequence &&
              !initial) {
            break;
          }
          _displayEpoch = epoch;
          _displaySequence = sequence;
          _expire?.cancel();
          item = message['item'] == null
              ? null
              : ClipItem.fromJson(
                  Map<String, dynamic>.from(message['item'] as Map),
                );
          final current = item;
          if (current == null || current.expired) {
            item = null;
            itemStatus = 'No text shared yet';
          } else {
            itemStatus = 'Available in app';
            _expire = Timer(current.remaining, () {
              if (item?.id == current.id) {
                item = null;
                itemStatus = 'Shared text expired';
                _notify();
              }
            });
            if (current.senderId == identity.id) {
              // An acknowledgement confirms publication; never write our echo back.
              final stillLocal =
                  current.id == _localPublicationItemId &&
                  _localPublicationRevision == _observedRevision &&
                  !_localDirty;
              itemStatus = stillLocal
                  ? 'Shared from this clipboard'
                  : 'Available in app';
              _receipt(current, stillLocal ? 'applied' : 'available');
            } else {
              _receipt(current, paused ? 'paused' : 'available');
              if (automatic &&
                  !paused &&
                  foreground &&
                  !_localDirty &&
                  !_resumeGuard &&
                  _pending == null &&
                  _candidate == null) {
                _queueApply(current);
              } else {
                if (_localDirty || _pending != null || _candidate != null) {
                  conflictText ??=
                      _candidate?.text ?? _pending?.message['text'] as String?;
                  _resumeGuard = true;
                }
                itemStatus = paused
                    ? 'Sharing paused'
                    : 'Tap Copy to use received text';
                _receipt(current, paused ? 'paused' : 'needsAction');
              }
            }
          }
          if (initial && _pending != null) unawaited(_retryPublication());
        case 'ack':
          if (_pending?.message['requestId'] == message['requestId']) {
            final publication = _pending!;
            _pending = null;
            _retry?.cancel();
            _sequence = max(_sequence, message['seq'] as int);
            if (_candidate == null &&
                publication.revision == _observedRevision) {
              _localDirty = false;
              conflictText = null;
            }
            if (publication.automatic) {
              _localPublicationItemId = message['itemId'] as String;
              _localPublicationRevision = publication.revision;
            }
            if (publication.automatic &&
                item?.id == message['itemId'] &&
                publication.revision == _observedRevision &&
                !_localDirty) {
              itemStatus = 'Shared from this clipboard';
              _receipt(item!, 'applied');
            }
            _coalesce?.cancel();
            _coalesce = Timer(
              const Duration(milliseconds: 250),
              () => unawaited(_drainCandidate()),
            );
          }
        case 'members':
          members = (message['devices'] as List)
              .map((d) => Map<String, dynamic>.from(d as Map))
              .toList();
        case 'error':
          final code = message['code'];
          final text = field(message, 'message', max: 512);
          if (code == 'unauthorized') {
            selectedHost = null;
            _client?.stop();
            connected = false;
            unawaited(preferences.remove('lastHost'));
          }
          if (message['requestId'] == _pending?.message['requestId'] &&
              _pending != null) {
            if (code == 'conflict') {
              conflictText =
                  _candidate?.text ?? _pending!.message['text'] as String;
              _resumeGuard = true;
            }
            _cancelPublication(text);
          }
          error = text;
        case 'disconnected':
          connected = false;
          _candidate = null;
          status = 'Connection interrupted · reconnecting';
          _scheduleReconnect();
        case 'hostError':
          connected = false;
          status = 'Hosting interrupted';
          networkChanged();
      }
    } catch (_) {
      error = 'The other device sent an invalid message. Connection stopped.';
      _client?.stop();
      connected = false;
    }
    _notify();
  }

  Future<void> setAutomatic(bool value) async {
    automatic = value && canAutomatic;
    await preferences.setBool('automatic', automatic);
    if (automatic) {
      _localDirty = false;
      await _baseline();
    } else {
      _cancelPublication(null);
    }
    _notify();
  }

  Future<void> setPaused(bool value) async {
    paused = value;
    _revision++;
    _cancelPublication(null);
    if (!paused) await _baseline();
    if (item != null) _receipt(item!, paused ? 'paused' : 'needsAction');
    _notify();
  }

  Future<void> _clipboardChanged() async {
    if (!automatic || paused || !foreground) return;
    if (_clipboardReading) {
      _clipboardReadAgain = true;
      return;
    }
    _clipboardReading = true;
    try {
      ClipboardSnapshot? snapshot;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          snapshot = await clipboard.read();
          break;
        } catch (_) {
          await Future<void>.delayed(
            Duration(milliseconds: 30 * (attempt + 1)),
          );
        }
      }
      if (snapshot == null || !automatic || paused || !foreground) return;
      if (snapshot.revision == _observedRevision) return;
      _observedRevision = snapshot.revision;
      if (snapshot.ownWrite) return;
      _revision++;
      _localDirty = true;
      _resumeGuard = false;
      if (item != null) {
        itemStatus = 'Local clipboard changed';
        _receipt(item!, 'needsAction');
      }
      if (snapshot.sensitive) {
        // Honour the source app's opt-out; Paste & Send can still share it.
        _candidate = null;
        _coalesce?.cancel();
        return;
      }
      if (!connected || _awaitingSnapshot) return;
      final text = snapshot.text;
      if (text == null || text.isEmpty) return;
      validText(text);
      _candidate = snapshot;
      _coalesce?.cancel();
      _coalesce = Timer(
        const Duration(milliseconds: 100),
        () => unawaited(_drainCandidate()),
      );
    } on FormatException {
      error =
          'This clipboard item cannot be shared. Use plain text up to 64 KiB.';
    } finally {
      _clipboardReading = false;
      if (_clipboardReadAgain) {
        _clipboardReadAgain = false;
        unawaited(_clipboardChanged());
      }
      _notify();
    }
  }

  Future<void> _drainCandidate() async {
    if (_pending != null ||
        _candidate == null ||
        !sharing ||
        !automatic ||
        _awaitingSnapshot) {
      return;
    }
    final candidate = _candidate!;
    _candidate = null;
    try {
      await sendText(
        candidate.text!,
        automaticSend: true,
        nativeRevision: candidate.revision,
      );
    } catch (failure) {
      showError(failure);
    }
  }

  Future<void> pasteAndSend() async {
    if (!sharing) throw SessionException('Connect and resume sharing first.');
    final snapshot = await clipboard.read();
    await sendText(validText(snapshot.text), nativeRevision: snapshot.revision);
  }

  Future<void> sendText(
    String text, {
    bool automaticSend = false,
    int? nativeRevision,
  }) async {
    validText(text);
    if (!sharing || _epoch == null || _awaitingSnapshot) {
      throw SessionException(
        'Wait for a connection and resume sharing before sending.',
      );
    }
    if (_pending != null) {
      throw SessionException('Waiting for the previous transfer.');
    }
    final publication = _Publication(
      {
        'type': 'publish',
        'requestId': randomSecret(16),
        'epoch': _epoch,
        'baseSeq': _sequence,
        'text': text,
      },
      automaticSend,
      nativeRevision,
    );
    _pending = publication;
    _notify();
    _retry?.cancel();
    _retry = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_retryPublication()),
    );
    await _retryPublication();
  }

  Future<void> _retryPublication() async {
    final publication = _pending;
    if (publication == null) return;
    if (publication.age.elapsed > const Duration(seconds: 10)) {
      conflictText ??= publication.message['text'] as String;
      _cancelPublication(
        'Delivery is unconfirmed. You can deliberately send again.',
      );
      _notify();
      return;
    }
    if (!sharing || _awaitingSnapshot) return;
    // A newer local copy may follow the in-flight request; never retransmit its predecessor.
    if (publication.automatic && _candidate != null) return;
    if (publication.message['epoch'] != _epoch) {
      _cancelPublication(
        'The host restarted. Send again to share current text.',
      );
      return;
    }
    try {
      if (host != null) {
        _message(host!.publish(publication.message));
      } else {
        await _client!.send(publication.message);
      }
    } on SessionException catch (failure) {
      if ({'conflict', 'rate', 'request'}.contains(failure.code)) {
        conflictText = publication.message['text'] as String;
        _cancelPublication(failure.message);
        if (host != null) _message(host!.engine.snapshot());
      }
    } catch (_) {
      /* Bounded retry timer owns transient delivery failures. */
    }
    _notify();
  }

  void _cancelPublication(String? reason) {
    _pending = null;
    _candidate = null;
    _retry?.cancel();
    _coalesce?.cancel();
    if (reason != null) error = reason;
  }

  void _receipt(ClipItem current, String status) {
    final message = <String, dynamic>{
      'type': 'receipt',
      'itemId': current.id,
      'status': status,
    };
    if (host != null) {
      host!.receipt(identity.id, message);
    } else if (connected || _client != null) {
      unawaited(_client?.send(message).catchError((Object _) {}));
    }
  }

  void _queueApply(ClipItem current) {
    final guard = _revision;
    _application = _application
        .then((_) async {
          final expectedRevision = _observedRevision;
          if (!sharing ||
              !automatic ||
              current.id != item?.id ||
              current.expired ||
              guard != _revision ||
              _localDirty ||
              _resumeGuard ||
              expectedRevision == null) {
            return;
          }
          for (var attempt = 0; attempt < 4; attempt++) {
            if (guard != _revision || !sharing || current.id != item?.id) {
              return;
            }
            try {
              final success = await clipboard.write(
                current.text,
                expectedRevision: expectedRevision,
              );
              if (!success) {
                _resumeGuard = true;
                break;
              }
              final snapshot = await clipboard.read();
              if (!snapshot.ownWrite || snapshot.text != current.text) {
                unawaited(_clipboardChanged());
                itemStatus = 'Local clipboard changed';
                _receipt(current, 'needsAction');
                _notify();
                return;
              }
              _observedRevision = snapshot.revision;
              itemStatus = 'Ready to paste';
              _receipt(current, 'applied');
              _notify();
              // Say who replaced the clipboard, so an unexpected paste is
              // noticed before it goes anywhere. Never include the text.
              unawaited(
                clipboard
                    .notify(
                      'Clipboard replaced',
                      'Text from ${current.senderName} is ready to paste.',
                    )
                    .catchError((Object _) {}),
              );
              return;
            } catch (_) {
              await Future<void>.delayed(
                Duration(milliseconds: 35 * (attempt + 1)),
              );
            }
          }
          itemStatus = 'Clipboard needs attention · tap Copy';
          _receipt(current, 'needsAction');
          _notify();
        })
        .catchError((Object _) {});
  }

  Future<void> copyReceived() async {
    final current = item;
    if (current == null || current.expired) {
      throw SessionException('There is no current shared text.');
    }
    if (paused || !foreground) {
      throw SessionException('Resume sharing before copying.');
    }
    _revision++;
    _cancelPublication(null);
    var success = false;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (current.id != item?.id || current.expired) break;
      try {
        success = await clipboard.write(current.text);
        if (success) break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (!success) {
      throw SessionException('Could not update the clipboard. Try Copy again.');
    }
    if (canAutomatic) {
      final snapshot = await clipboard.read();
      _observedRevision = snapshot.revision;
    }
    _localDirty = false;
    _resumeGuard = false;
    conflictText = null;
    itemStatus = 'Ready to paste';
    _receipt(current, 'applied');
    _notify();
  }

  Future<void> copyInvitation(String text) async {
    // Pairing material stays local and must survive incoming auto-sync writes.
    _revision++;
    _cancelPublication(null);
    _resumeGuard = true;
    _localDirty = true;
    if (!await clipboard.write(text)) {
      throw SessionException('Could not copy the invitation. Try again.');
    }
    if (canAutomatic) {
      _observedRevision = (await clipboard.read()).revision;
    }
    if (item != null) {
      itemStatus = 'Invitation copied locally';
      _receipt(item!, 'needsAction');
    }
    _notify();
  }

  Future<void> sendMine() async {
    final text = conflictText;
    if (text == null) return;
    _cancelPublication(null);
    conflictText = null;
    _resumeGuard = false;
    await sendText(text);
  }

  Future<void> setKeepAwake(bool value) async {
    await clipboard.keepAwake(value && hosting);
    keepScreenAwake = value && hosting;
    _notify();
  }

  Future<void> setForeground(bool value) async {
    if (!mobile || foreground == value) return;
    foreground = value;
    _revision++;
    if (!value) {
      item = null;
      _expire?.cancel();
      _cancelPublication(null);
      _reconnect?.cancel();
      _resumeGuard = true;
      pendingPair?.decide(false);
      invitation = null;
      _client?.stop();
      connected = false;
      if (hosting) {
        await leave();
        status = 'Phone hosting stopped while app was backgrounded';
      }
      await clipboard.keepAwake(false);
      keepScreenAwake = false;
      try {
        await discovery.stop();
      } catch (_) {}
    } else {
      try {
        await discovery.start();
      } catch (_) {}
      _connecting = false;
      await _connect();
    }
    _notify();
  }

  void networkChanged() {
    _networkTimer?.cancel();
    _networkTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_networkChanged()),
    );
  }

  Future<void> _networkChanged() async {
    if (!foreground || _rebindBusy) return;
    _rebindBusy = true;
    try {
      final before = {for (final i in interfaces) i.address};
      interfaces = await LanInterface.list();
      final unchanged =
          before.length == interfaces.length &&
          interfaces.every((i) => before.contains(i.address));
      if (hosting) {
        final old = host!;
        // Stay on the adapter the user chose. Falling back to whichever is
        // first can strand the host on a virtual or link-local adapter.
        final interface = interfaces
            .where((i) => i.name == _interfaceName)
            .firstOrNull;
        if (interface == null) {
          connected = false;
          status = 'Waiting for $_interfaceName · restart hosting to switch';
        } else if (!connected || interface.address != old.address) {
          connected = false;
          await old.rebind(interface.address);
          invitation = null;
          _interfaceName = interface.name;
          connected = true;
          status = 'Hosting on ${interface.address}';
          try {
            await discovery.advertise(
              identity.id,
              name,
              interface.address,
              old.port,
            );
          } catch (_) {}
        }
      } else if (selectedHost != null && !(connected && unchanged)) {
        // VPN, Hyper-V, and Bluetooth adapters raise events too; a working
        // session on unchanged addresses is left alone. Heartbeats still
        // catch a connection that died silently.
        _client?.stop();
        _connectionGeneration++;
        _connecting = false;
        await _connect();
      }
    } catch (_) {
      status = 'Waiting for a local network';
      if (hosting) {
        // A failed rebind leaves the host closed; retry without a new event.
        connected = false;
        _networkTimer?.cancel();
        _networkTimer = Timer(
          const Duration(seconds: 5),
          () => unawaited(_networkChanged()),
        );
      }
    } finally {
      _rebindBusy = false;
      _notify();
    }
  }

  Future<void> forgetHost(SavedHost saved) async {
    if (selectedHost?.id == saved.id) await leave();
    trust.hosts.remove(saved.id);
    await trust.save();
    _notify();
  }

  Future<void> leave() async {
    _connectionGeneration++;
    _connecting = false;
    _reconnect?.cancel();
    _cancelPublication(null);
    _expire?.cancel();
    await _sessionSub?.cancel();
    _sessionSub = null;
    await _pairSub?.cancel();
    _pairSub = null;
    _client?.stop();
    _client = null;
    selectedHost = null;
    final localHost = host;
    host = null;
    await localHost?.stop();
    try {
      await discovery.stopAdvertising();
    } catch (_) {}
    await clipboard.keepAwake(false);
    keepScreenAwake = false;
    connected = false;
    invitation = null;
    pendingPair?.decide(false);
    pendingPair = null;
    members = [];
    item = null;
    itemStatus = 'No text shared yet';
    conflictText = null;
    _epoch = null;
    _displayEpoch = null;
    _displaySequence = -1;
    _sequence = 0;
    _attempt = 0;
    _awaitingSnapshot = true;
    status = 'Ready to connect';
    await preferences.remove('lastHost');
    _notify();
  }

  Future<void> quit() async {
    final reconnectHost = selectedHost?.id;
    await leave();
    if (reconnectHost != null) {
      await preferences.setString('lastHost', reconnectHost);
    }
    try {
      await discovery.stop();
    } catch (_) {}
    await clipboard.quit();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _coalesce?.cancel();
    _retry?.cancel();
    _expire?.cancel();
    _networkTimer?.cancel();
    unawaited(_clipboardSub?.cancel());
    unawaited(_actionSub?.cancel());
    unawaited(_sessionSub?.cancel());
    unawaited(_pairSub?.cancel());
    _client?.stop();
    if (host != null) unawaited(host!.stop());
    super.dispose();
  }
}
