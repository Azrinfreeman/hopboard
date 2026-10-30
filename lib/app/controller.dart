import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/client.dart';
import '../core/host.dart';
import '../core/identity.dart';
import '../core/pair_code.dart';
import '../core/protocol.dart';
import '../core/content.dart';
import '../core/image_content.dart';
import '../core/file_content.dart';
import '../core/zip_content.dart';
import '../core/version.dart';
import '../platform/clipboard_bridge.dart';
import '../platform/discovery.dart';
import '../platform/secure_vault.dart';
import '../platform/update_service.dart';

/// Stored identity or trust could not be read, e.g. after a password reset
/// made DPAPI data unreadable or the Android Keystore key was invalidated.
class StorageFailure implements Exception {
  StorageFailure(this.cause);
  final Object cause;
  @override
  String toString() => 'Secure storage is unavailable: $cause';
}

class _Publication {
  _Publication(
    this.message,
    this.automatic,
    this.revision,
    this.snapshot,
    this.files,
  );
  final Map<String, dynamic> message;
  final bool automatic;
  final int? revision;
  final ClipboardSnapshot snapshot;
  final FileContent? files;
  final age = Stopwatch()..start();
}

class AppController extends ChangeNotifier {
  AppController({
    required this.identity,
    required this.trust,
    required this.clipboard,
    required this.discovery,
    required this.preferences,
    UpdateService? updates,
  }) : updates = updates ?? UpdateService();
  final UpdateService updates;
  String? newerVersion, hostUpdateNotice;
  bool updateDismissed = false, updateBusy = false;
  double? updateProgress;
  bool get updateAvailable => newerVersion != null && !updateDismissed;
  bool get canInstallUpdate => Platform.isWindows;
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
  bool automaticImages = false;
  bool automaticFiles = false;
  bool packagingFiles = false;
  Future<File>? _zipPreparation;
  bool _clearingFiles = false;
  int fileLimit = defaultItemBytes;
  int autoDownloadLimit = 256 * 1024 * 1024;
  final Map<Directory, DateTime> _outgoingZips = {};

  FileContent? _outgoingFiles;
  ReceivedFiles? _receivedFiles;
  String? _receivedFilesId;
  Future<ReceivedFiles>? _fileDownload;
  final Map<ReceivedFiles, DateTime> _fileCaches = {};
  final Map<ReceivedFiles, int> _cacheRevisions = {};
  Timer? _cacheSweep;
  bool get filesReady => _receivedFilesId == item?.id && _receivedFiles != null;
  bool get needsFileDownload => item?.kind == 'files' && !filesReady;

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
  ClipboardSnapshot? conflictPayload;
  String? get conflictText => conflictPayload?.text;
  set conflictText(String? value) =>
      conflictPayload = value == null ? null : ClipboardSnapshot(value, 0);
  bool get hasConflict => conflictPayload != null;
  Uint8List? _outgoingPng, _receivedPng;
  String? _outgoingId, _receivedId;
  Uint8List? get receivedImage => _receivedId == item?.id
      ? _receivedPng
      : _outgoingId == item?.id
      ? _outgoingPng
      : null;
  int? imageProgress;
  int _downloadGeneration = 0;
  Future<Uint8List>? _download;
  Completer<void>? _imageReady;
  List<Map<String, dynamic>> members = [];
  List<LanInterface> interfaces = [];
  StreamSubscription<Map<String, dynamic>>? _sessionSub;
  StreamSubscription<PairRequest>? _pairSub;
  StreamSubscription<void>? _clipboardSub;
  StreamSubscription<List<String>>? _fileDropSub;
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
    if (Platform.isWindows) {
      final cache = await ClipboardBridge().receiveCache();
      await for (final entry in cache.list(followLinks: false)) {
        await entry.delete(recursive: true);
      }
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
    fileLimit = (preferences.getInt('fileLimit') ?? defaultItemBytes).clamp(
      16 * 1024 * 1024,
      defaultItemBytes,
    );
    autoDownloadLimit =
        (preferences.getInt('autoDownloadLimit') ?? 256 * 1024 * 1024).clamp(
          0,
          defaultItemBytes,
        );
    automaticFiles =
        clipboard.supportsFiles &&
        (preferences.getBool('automaticFiles') ?? false);
    if (clipboard.supportsFiles) {
      await clearReceivedFiles();
      _cacheSweep = Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(
          _sweepFileCaches().catchError((Object failure) {
            showError(failure);
          }),
        ),
      );
    }
    automaticImages =
        clipboard.supportsImages &&
        (preferences.getBool('automaticImages') ?? false);
    _lastHostId = preferences.getString('lastHost');
    await clipboard.initialize();
    _fileDropSub = clipboard.fileDrops.stream.listen((paths) {
      unawaited(
        sendFiles(paths).catchError((Object failure) {
          showError(failure);
        }),
      );
    });
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
      final localHost = LocalHost(
        identity,
        trust,
        name,
        content: clipboard.supportsImages,
      );
      localHost.transfers.source = _imageSource;
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
          content: clipboard.supportsImages,
        );
        client.transfers.source = _imageSource;
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
      } else if (failure is SessionException && failure.code == 'certificate') {
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
              ? snapshot.hasContent
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
          _checkVersion(message['appVersion']);
          hostUpdateNotice =
              message['features'] is! List ||
                  !(message['features'] as List).contains(contentFeature)
              ? '${selectedHost?.name ?? 'The host'} supports text only. Update Hopboard on that device to share images.'
              : null;
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
            if (sequence == _displaySequence &&
                message['availability'] == 'ready' &&
                message['item'] is Map &&
                (message['item'] as Map)['id'] == item?.id &&
                _imageReady?.isCompleted == false) {
              _imageReady!.complete();
            }
            break;
          }
          _cancelImageReceive();
          _receivedPng = null;
          _receivedId = null;
          _displayEpoch = epoch;
          _displaySequence = sequence;
          _expire?.cancel();
          item = message['item'] == null
              ? null
              : ClipItem.fromJson(
                  Map<String, dynamic>.from(message['item'] as Map),
                );
          final current = item;
          if (current?.senderId != identity.id) {
            _outgoingId = null;
            _outgoingPng = null;
            _outgoingFiles = null;
          }
          _imageReady = Completer<void>();
          if (message['availability'] != 'uploading') _imageReady!.complete();
          if (current == null || current.expired) {
            item = null;
            itemStatus = 'No text shared yet';
          } else {
            itemStatus = 'Available in app';
            _expire = Timer(current.remaining, () {
              if (item?.id == current.id) {
                _cancelImageReceive();
                _outgoingPng = null;
                _outgoingId = null;
                _receivedPng = null;
                _receivedId = null;
                item = null;
                itemStatus = 'Shared text expired';
                _notify();
              }
            });
            if (current.senderId == identity.id) {
              if (_pending?.files != null) {
                _outgoingId = current.id;
                _outgoingFiles = _pending!.files;
              }
              if (_pending?.snapshot.png != null) {
                _outgoingId = current.id;
                _outgoingPng = _pending!.snapshot.png;
              }
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
              if (_autoAccepts(current) &&
                  !paused &&
                  foreground &&
                  !_localDirty &&
                  !_resumeGuard &&
                  _pending == null &&
                  _candidate == null) {
                _queueApply(current);
              } else {
                if (_localDirty || _pending != null || _candidate != null) {
                  conflictPayload ??= _candidate ?? _pending?.snapshot;
                  _resumeGuard = true;
                }
                itemStatus = paused
                    ? 'Sharing paused'
                    : current.payload.isText
                    ? 'Tap Copy to use received text'
                    : current.kind == 'files'
                    ? 'Download to copy files'
                    : 'Tap Copy to use received image';
                _receipt(current, paused ? 'paused' : 'needsAction');
                if (current.kind == 'files' && !paused) {
                  unawaited(
                    clipboard
                        .notify(
                          'Files available',
                          '${current.senderName} shared ${(current.payload.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MiB. Open Hopboard to download.',
                        )
                        .catchError((Object _) {}),
                  );
                }
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
            if (publication.files != null) {
              _outgoingId = message['itemId'] as String;
              _outgoingFiles = publication.files;
              unawaited(_uploadFiles(_outgoingId!, publication.files!));
            }
            if (publication.snapshot.png != null) {
              _outgoingId = message['itemId'] as String;
              _outgoingFiles = null;
              _outgoingPng = publication.snapshot.png;
              unawaited(_uploadImage(_outgoingId!, publication.snapshot.png!));
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
          for (final member in members) {
            _checkVersion(member['appVersion']);
          }
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
              conflictPayload = _candidate ?? _pending!.snapshot;
              _resumeGuard = true;
            }
            _cancelPublication(text);
          }
          error = text;
        case 'disconnected':
          _cancelImageReceive();
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
    _revision++;
    automatic = value && canAutomatic;
    await preferences.setBool('automatic', automatic);
    if (automatic) {
      _localDirty = false;
      await _baseline();
    } else {
      _cancelPublication(null);
      _cancelImageReceive();
    }
    _notify();
  }

  void _checkVersion(Object? version) {
    if (version is String &&
        (compareVersions(version, applicationVersion) ?? 0) > 0 &&
        (newerVersion == null ||
            (compareVersions(version, newerVersion!) ?? 0) > 0)) {
      newerVersion = version;
      updateDismissed = false;
    }
  }

  void dismissUpdate() {
    updateDismissed = true;
    hostUpdateNotice = null;
    _notify();
  }

  Future<PreparedUpdate?> prepareUpdate() async {
    if (updateBusy || !canInstallUpdate) return null;
    updateBusy = true;
    updateProgress = null;
    _notify();
    try {
      final update = await updates.prepare(
        progress: (value) {
          updateProgress = value;
          _notify();
        },
      );
      if (update == null) {
        error = 'This device already has the latest published version.';
      }
      return update;
    } finally {
      updateBusy = false;
      updateProgress = null;
      _notify();
    }
  }

  Future<void> installUpdate(PreparedUpdate update) async {
    await leave();
    await updates.install(update);
  }

  Future<void> setAutomaticImages(bool value) async {
    automaticImages = value && clipboard.supportsImages;
    await preferences.setBool('automaticImages', automaticImages);
    _cancelImageReceive();
    _cancelPublication(null);
    _revision++;
    await _baseline();
    _notify();
  }

  bool _autoAccepts(ClipItem current) =>
      automatic &&
      (current.payload.isText ||
          automaticImages && current.payload.image != null ||
          automaticFiles &&
              autoDownloadLimit > 0 &&
              current.kind == 'files' &&
              current.payload.totalBytes <= autoDownloadLimit &&
              current.payload.totalBytes <= fileLimit);

  Future<void> setPaused(bool value) async {
    paused = value;
    _revision++;
    _cancelImageReceive();
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
          snapshot = automaticImages || automaticFiles
              ? await clipboard.readContent(includeImages: automaticImages)
              : await clipboard.read();
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
      _cancelImageReceive();
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
      if (snapshot.hasFiles && (!automaticFiles || snapshot.cut)) return;
      final text = snapshot.text;
      if (!snapshot.hasFiles &&
          snapshot.png == null &&
          (text == null || text.isEmpty)) {
        return;
      }
      if (!snapshot.hasFiles && text?.isNotEmpty == true) validText(text);
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
      await _sendSnapshot(
        candidate,
        automaticSend: true,
        nativeRevision: candidate.revision,
      );
    } catch (failure) {
      showError(failure);
    }
  }

  Future<void> pasteAndSend() async {
    if (!sharing) throw SessionException('Connect and resume sharing first.');
    final snapshot = clipboard.supportsImages
        ? await clipboard.readContent()
        : await clipboard.read();
    if (snapshot.cut) {
      throw SessionException('Use Copy instead of Cut to share files.');
    }
    await _sendSnapshot(snapshot, nativeRevision: snapshot.revision);
  }

  Future<void> sendText(
    String text, {
    bool automaticSend = false,
    int? nativeRevision,
  }) async {
    validText(text);
    await _sendSnapshot(
      ClipboardSnapshot(text, nativeRevision ?? 0),
      automaticSend: automaticSend,
      nativeRevision: nativeRevision,
    );
  }

  Future<void> _sendSnapshot(
    ClipboardSnapshot snapshot, {
    bool automaticSend = false,
    int? nativeRevision,
  }) async {
    final generation = _connectionGeneration;
    final files = snapshot.hasFiles
        ? await FileContent.create(
            snapshot.filePaths,
            inspect: clipboard.inspectFile,
            limit: fileLimit,
          )
        : null;
    final content = snapshot.png == null
        ? null
        : await ImageContent.create(snapshot.png!, text: snapshot.text);
    final payload =
        files?.payload ??
        content?.payload ??
        ClipPayload.fromJson({'text': validText(snapshot.text)});
    if (generation != _connectionGeneration ||
        automaticSend && nativeRevision != _observedRevision) {
      return;
    }
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
        ...payload.toJson(),
      },
      automaticSend,
      nativeRevision,
      snapshot,
      files,
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
      conflictPayload ??= publication.snapshot;
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
        conflictPayload = publication.snapshot;
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

  void _receipt(ClipItem current, String status, {int? progress}) {
    final message = <String, dynamic>{
      'type': 'receipt',
      'itemId': current.id,
      'status': status,
      'progress': ?progress,
    };
    if (host != null) {
      host!.receipt(identity.id, message);
    } else if (connected || _client != null) {
      unawaited(_client?.send(message).catchError((Object _) {}));
    }
  }

  Future<Stream<List<int>>> _imageSource(
    String id,
    int entry,
    int offset,
  ) async {
    final files = _outgoingFiles;
    if (sharing && id == _outgoingId && files != null) {
      return files.open(entry, offset, inspect: clipboard.inspectFile);
    }
    final bytes = _outgoingPng;
    if (!sharing ||
        id != _outgoingId ||
        bytes == null ||
        entry != 0 ||
        offset > bytes.length) {
      throw SessionException(
        'The copied image is no longer available.',
        'expired',
      );
    }
    return Stream.value(Uint8List.sublistView(bytes, offset));
  }

  Future<void> _uploadImage(String id, Uint8List png) async {
    final generation = _downloadGeneration;
    try {
      final local = host;
      if (local != null) {
        if (local.engine.item?.id != id) return;
        local.transfers.blobs.put(id, 0, Uint8List.fromList(png));
        local.refreshContent();
      } else {
        final current = item;
        if (current?.id != id) return;
        await _client!.transfers.upload(current!);
      }
    } catch (_) {
      if (generation == _downloadGeneration && item?.id == id) {
        error = 'The image could not be uploaded. Copy it again to retry.';
        _notify();
      }
    }
  }

  void _cancelImageReceive() {
    unawaited(clipboard.cancelImageWrite().catchError((Object _) {}));
    _downloadGeneration++;
    _download = null;
    _fileDownload = null;
    imageProgress = null;
    if (_imageReady?.isCompleted == false) _imageReady!.complete();
    _client?.transfers.cancel();
    host?.transfers.forget(identity.id);
  }

  Future<void> setFileLimits({int? itemBytes, int? automaticBytes}) async {
    fileLimit = (itemBytes ?? fileLimit).clamp(
      16 * 1024 * 1024,
      defaultItemBytes,
    );
    autoDownloadLimit = (automaticBytes ?? autoDownloadLimit).clamp(
      0,
      defaultItemBytes,
    );
    await preferences.setInt('fileLimit', fileLimit);
    await preferences.setInt('autoDownloadLimit', autoDownloadLimit);
    _revision++;
    _cancelImageReceive();
    _notify();
  }

  Future<void> sendAsZip() async {
    if (!sharing || packagingFiles || _clearingFiles) return;
    final paths = await clipboard.pickFiles(folder: true);
    if (paths.isEmpty || !sharing) return;
    final generation = _connectionGeneration;
    final revision = _revision;
    void check() {
      if (!sharing ||
          generation != _connectionGeneration ||
          revision != _revision) {
        throw SessionException('ZIP preparation cancelled.');
      }
    }

    packagingFiles = true;
    _notify();
    try {
      final cache = await clipboard.receiveCache();
      final preparation = packageFiles(
        paths,
        cache,
        inspect: clipboard.inspectFile,
        check: check,
        reserveSpace: (bytes) => _checkFileSpace(cache, bytes),
        limit: fileLimit,
      );
      _zipPreparation = preparation;
      final file = await preparation;
      _outgoingZips[file.parent] = DateTime.now().add(fileLifetime);
      await sendFiles([file.path]);
    } finally {
      _zipPreparation = null;
      packagingFiles = false;
      _notify();
    }
  }

  Future<void> pickFiles({bool folder = false}) async {
    if (!sharing) throw SessionException('Connect and resume sharing first.');
    final paths = await clipboard.pickFiles(folder: folder);
    if (paths.isNotEmpty) await sendFiles(paths);
  }

  Future<void> sendFiles(List<String> paths) => _sendSnapshot(
    ClipboardSnapshot(null, 0, hasFiles: true, filePaths: paths),
  );

  Future<void> showReceivedFolder() async {
    if (filesReady) {
      await clipboard.showReceivedFolder(_receivedFiles!.directory.path);
    }
  }

  Future<void> setAutomaticFiles(bool value) async {
    automaticFiles = value && clipboard.supportsFiles;
    await preferences.setBool('automaticFiles', automaticFiles);
    _revision++;
    _cancelImageReceive();
    await _baseline();
    _notify();
  }

  Future<void> _uploadFiles(String id, FileContent files) async {
    if (!files.payload.cached) return;
    try {
      final local = host;
      if (local != null) {
        for (final entry in files.payload.streams.keys) {
          final builder = BytesBuilder(copy: false);
          await for (final bytes in files.open(
            entry,
            0,
            inspect: clipboard.inspectFile,
          )) {
            if (_outgoingId != id || !sharing) return;
            builder.add(bytes);
          }
          if (_outgoingId != id || local.engine.item?.id != id) return;
          local.transfers.blobs.put(id, entry, builder.takeBytes());
        }
        local.refreshContent();
      } else {
        final current = item;
        if (current?.id == id) await _client!.transfers.upload(current!);
      }
    } catch (_) {
      if (_outgoingId == id) {
        error = 'Files could not be uploaded. Copy them again to retry.';
        _notify();
      }
    }
  }

  Future<ReceivedFiles> _ensureFiles(ClipItem current) {
    if (filesReady && current.id == _receivedFilesId) {
      return Future.value(_receivedFiles!);
    }
    if (_fileDownload != null) return _fileDownload!;
    final generation = _downloadGeneration;
    void check() {
      if (generation != _downloadGeneration ||
          _clearingFiles ||
          item?.id != current.id ||
          current.expired ||
          !sharing) {
        throw SessionException('File transfer cancelled.', 'expired');
      }
    }

    final future = (() async {
      try {
        check();
        if (!clipboard.supportsFiles) {
          throw SessionException(
            'File clipboard is unavailable on this device.',
          );
        }
        if (current.payload.totalBytes > fileLimit) {
          throw SessionException('Files exceed your item size limit.');
        }
        imageProgress = 0;
        _receipt(current, 'downloading', progress: 0);
        final receiptClock = Stopwatch()..start();
        itemStatus = 'Downloading files';
        _notify();
        await (_imageReady?.future ?? Future<void>.value()).timeout(
          const Duration(seconds: 30),
        );
        check();
        final cache = await clipboard.receiveCache();
        await _checkFileSpace(cache, current.payload.totalBytes);
        check();
        final result = await ReceivedFiles.receive(
          cache,
          current.payload.files!,
          (entry, write) async {
            check();
            if (host != null) {
              await host!.transfers.fetchLocal(
                current,
                entry,
                (chunk) => write(chunk),
              );
            } else {
              await _client!.transfers.fetch(
                current,
                entry,
                (chunk) => write(chunk),
              );
            }
          },
          check: check,
          markDownloaded: (path) async {
            await File('$path:Zone.Identifier')
                .writeAsString('[ZoneTransfer]\r\nZoneId=3\r\n', flush: true);
          },
          progress: (value) {
            if (imageProgress != value) {
              imageProgress = value;
              itemStatus = 'Downloading files $value%';
              if (value == 100 || receiptClock.elapsedMilliseconds >= 500) {
                _receipt(current, 'downloading', progress: value);
                receiptClock.reset();
              }
              _notify();
            }
          },
        );
        try {
          check();
        } catch (_) {
          await result.delete();
          rethrow;
        }
        _receivedFiles = result;
        _receivedFilesId = current.id;
        _fileCaches[result] = DateTime.now().add(
          current.remaining + const Duration(hours: 1),
        );
        return result;
      } catch (failure) {
        if (generation == _downloadGeneration && item?.id == current.id) {
          itemStatus = failure is SessionException
              ? failure.message
              : 'Download failed - retry Download';
          _receipt(current, 'needsAction');
          _notify();
        }
        rethrow;
      } finally {
        if (generation == _downloadGeneration) {
          imageProgress = null;
          _fileDownload = null;
          _notify();
        }
      }
    })();
    _fileDownload = future;
    return future;
  }

  void cancelFileDownload() {
    _revision++;
    _cancelImageReceive();
    itemStatus = 'Download cancelled';
    if (item != null) _receipt(item!, 'needsAction');
    _notify();
  }

  Future<void> _sweepFileCaches() async {
    if (_clearingFiles) return;
    final snapshot = await clipboard.read();
    for (final entry in _outgoingZips.entries.toList()) {
      final paths = [
        ...?_outgoingFiles?.paths.values,
        ...?_pending?.files?.paths.values,
      ];
      if (DateTime.now().isAfter(entry.value) ||
          !packagingFiles &&
              !paths.any((p) => File(p).parent.path == entry.key.path)) {
        if (await entry.key.exists()) await entry.key.delete(recursive: true);
        _outgoingZips.remove(entry.key);
      }
    }
    for (final entry in _fileCaches.entries.toList()) {
      if (DateTime.now().isAfter(entry.value) ||
          (entry.key != _receivedFiles || _receivedFilesId != item?.id) &&
              _cacheRevisions[entry.key] != snapshot.revision) {
        await entry.key.delete();
        _fileCaches.remove(entry.key);
        _cacheRevisions.remove(entry.key);
        if (entry.key == _receivedFiles) {
          _receivedFiles = null;
          _receivedFilesId = null;
        }
      }
    }
  }

  Future<void> _checkFileSpace(Directory cache, int bytes) async {
    await _sweepFileCaches();
    await checkFileCacheSpace(
      cache,
      incomingBytes: bytes,
      cacheLimit: 2 * fileLimit,
      availableBytes: await clipboard.availableFileSpace(cache.path),
    );
  }

  Future<void> clearReceivedFiles() async {
    if (!clipboard.supportsFiles || _clearingFiles) return;
    _clearingFiles = true;
    try {
      _revision++;
      final pendingDownload = _fileDownload;
      _cancelImageReceive();
      try {
        await pendingDownload;
      } catch (_) {}
      try {
        await _zipPreparation;
      } catch (_) {}
      final cache = await clipboard.receiveCache();
      if (await cache.exists()) {
        await for (final entry in cache.list(followLinks: false)) {
          if (await FileSystemEntity.type(entry.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            await Directory(entry.path).delete(recursive: true);
          } else {
            await entry.delete();
          }
        }
      }
      _fileCaches.clear();
      _cacheRevisions.clear();
      _outgoingZips.clear();
      _receivedFiles = null;
      _receivedFilesId = null;
      _notify();
    } finally {
      _clearingFiles = false;
    }
  }

  Future<Uint8List> _ensureImage(ClipItem current) {
    final existing = receivedImage;
    if (existing != null && current.id == item?.id) {
      return Future.value(existing);
    }
    if (!clipboard.supportsImages || current.payload.image == null) {
      return Future.error(
        SessionException(
          'This device cannot receive this content. Update Hopboard.',
        ),
      );
    }
    if (_download != null) return _download!;
    final generation = _downloadGeneration;
    final ready = _imageReady?.future ?? Future<void>.value();
    final future = (() async {
      void check() {
        if (generation != _downloadGeneration ||
            current.id != item?.id ||
            current.expired ||
            !sharing) {
          throw SessionException('Image transfer cancelled.', 'expired');
        }
      }

      try {
        itemStatus = 'Receiving image…';
        imageProgress = 0;
        _notify();
        await ready.timeout(const Duration(seconds: 30));
        check();
        final bytes = Uint8List(current.payload.image!.size);
        var offset = 0;
        Future<void> write(Uint8List chunk) async {
          check();
          bytes.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
          final progress = (offset * 100 / bytes.length).floor();
          if (progress != imageProgress) {
            imageProgress = progress;
            _notify();
          }
        }

        if (host != null) {
          await host!.transfers.fetchLocal(current, 0, write);
        } else {
          await _client!.transfers.fetch(current, 0, write);
        }
        await ImageContent.verify(current.payload, bytes);
        check();
        _receivedId = current.id;
        _receivedPng = bytes;
        return bytes;
      } finally {
        if (generation == _downloadGeneration) {
          imageProgress = null;
          _download = null;
          _notify();
        }
      }
    })();
    _download = future;
    return future;
  }

  Future<bool> _writeItem(ClipItem current, int? expectedRevision) async {
    if (current.payload.image != null) {
      return clipboard.writeImage(
        await _ensureImage(current),
        text: current.payload.text,
        expectedRevision: expectedRevision,
      );
    }
    if (current.kind == 'files') {
      final files = await _ensureFiles(current);
      return clipboard.writeFiles(
        files.roots,
        expectedRevision: expectedRevision,
      );
    }
    return clipboard.write(current.text, expectedRevision: expectedRevision);
  }

  Future<ClipboardSnapshot> _readApplied(ClipItem current) async {
    final snapshot = current.kind == 'files'
        ? await clipboard.readContent(includeImages: false)
        : current.payload.image == null
        ? await clipboard.read()
        : await clipboard.readContent();
    if (current.kind == 'files' &&
        _matches(snapshot, current) &&
        _receivedFiles != null) {
      _cacheRevisions[_receivedFiles!] = snapshot.revision;
    }
    return snapshot;
  }

  bool _matches(ClipboardSnapshot snapshot, ClipItem current) =>
      snapshot.ownWrite &&
      (current.kind != 'files' ||
          listEquals(snapshot.filePaths, _receivedFiles?.roots)) &&
      (current.payload.text == null || snapshot.text == current.text) &&
      (current.payload.image == null ||
          listEquals(snapshot.png, receivedImage));

  Future<bool> _fallbackMixed(
    ClipItem current,
    int guard,
    int? expected,
  ) async {
    if (current.kind != 'mixed' ||
        guard != _revision ||
        !sharing ||
        current.id != item?.id ||
        current.expired) {
      return false;
    }
    try {
      final before = await clipboard.read();
      if (guard != _revision ||
          current.id != item?.id ||
          before.revision != expected &&
              !(before.ownWrite && before.text == current.text)) {
        return false;
      }
      if (!(before.ownWrite && before.text == current.text) &&
          !await clipboard.write(
            current.text,
            expectedRevision: before.revision,
          )) {
        return false;
      }
      final after = await clipboard.read();
      if (!after.ownWrite || after.text != current.text) return false;
      _observedRevision = after.revision;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _queueApply(ClipItem current) {
    final guard = _revision;
    _application = _application
        .then((_) async {
          final expectedRevision = _observedRevision;
          if (!sharing ||
              !_autoAccepts(current) ||
              current.id != item?.id ||
              current.expired ||
              guard != _revision ||
              _localDirty ||
              _resumeGuard ||
              expectedRevision == null) {
            return;
          }
          if (current.kind == 'files') {
            try {
              await _ensureFiles(current);
            } catch (_) {
              return;
            }
          }
          if (current.payload.image != null) {
            try {
              await _ensureImage(current);
            } catch (_) {
              if (guard == _revision &&
                  sharing &&
                  current.id == item?.id &&
                  !current.expired) {
                if (await _fallbackMixed(current, guard, expectedRevision)) {
                  itemStatus = 'Text ready · image needs attention';
                } else {
                  itemStatus = 'Image needs attention · tap Copy image';
                }
                _receipt(current, 'needsAction');
                _notify();
              }
              return;
            }
          }
          for (var attempt = 0; attempt < 4; attempt++) {
            if (guard != _revision ||
                !sharing ||
                !_autoAccepts(current) ||
                current.id != item?.id) {
              return;
            }
            try {
              final success = await _writeItem(current, expectedRevision);
              if (!success) {
                _resumeGuard = true;
                break;
              }
              final snapshot = await _readApplied(current);
              if (!_matches(snapshot, current)) {
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
                      '${current.kind == 'files'
                          ? 'Files'
                          : current.payload.isText
                          ? 'Text'
                          : 'Image'} from ${current.senderName} is ready to paste.',
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
          itemStatus = await _fallbackMixed(current, guard, expectedRevision)
              ? 'Text ready · image needs attention'
              : 'Clipboard needs attention · tap Copy';
          _receipt(current, 'needsAction');
          _notify();
        })
        .catchError((Object _) {});
  }

  Future<void> copyReceived() {
    final current = item;
    if (current == null || current.expired) {
      return Future.error(SessionException('There is no current shared item.'));
    }
    _revision++;
    unawaited(clipboard.cancelImageWrite().catchError((Object _) {}));
    final result = _application.then((_) => _copyReceived(current));
    _application = result.catchError((Object _) {});
    return result;
  }

  Future<void> _copyReceived(ClipItem current) async {
    if (current.id != item?.id || current.expired) {
      throw SessionException('The shared item changed. Try Copy again.');
    }
    if (paused || !foreground) {
      throw SessionException('Resume sharing before copying.');
    }
    _revision++;
    _cancelPublication(null);
    final guard = _revision;
    final expected = canAutomatic ? (await clipboard.read()).revision : null;
    if (current.kind == 'files') await _ensureFiles(current);
    if (current.payload.image != null) {
      try {
        await _ensureImage(current);
      } catch (_) {
        if (await _fallbackMixed(current, guard, expected)) {
          itemStatus = 'Text ready · image needs attention';
          _receipt(current, 'needsAction');
          _notify();
        }
        rethrow;
      }
    }
    var success = false;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (guard != _revision ||
          current.id != item?.id ||
          current.expired ||
          !sharing) {
        break;
      }
      try {
        success = await _writeItem(current, expected);
        if (success) break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (!success) {
      if (await _fallbackMixed(current, guard, expected)) {
        itemStatus = 'Text ready · image needs attention';
        _receipt(current, 'needsAction');
        _notify();
      }
      throw SessionException('Could not update the clipboard. Try Copy again.');
    }
    if (canAutomatic) {
      final snapshot = await _readApplied(current);
      if (!_matches(snapshot, current)) {
        throw SessionException(
          'Your newer local copy was preserved. Try Copy again.',
        );
      }
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
    _cancelImageReceive();
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
    final content = conflictPayload;
    if (content == null) return;
    _cancelPublication(null);
    conflictText = null;
    _resumeGuard = false;
    await _sendSnapshot(content);
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
    _cancelImageReceive();
    _receivedPng = null;
    _receivedId = null;
    _outgoingPng = null;
    _outgoingFiles = null;
    _outgoingId = null;
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
    await clearReceivedFiles();
    await clipboard.quit();
  }

  @override
  void dispose() {
    _cancelImageReceive();
    _cacheSweep?.cancel();
    _disposed = true;
    _reconnect?.cancel();
    _coalesce?.cancel();
    _retry?.cancel();
    _expire?.cancel();
    _networkTimer?.cancel();
    unawaited(_clipboardSub?.cancel());
    unawaited(_fileDropSub?.cancel());
    unawaited(_actionSub?.cancel());
    unawaited(_sessionSub?.cancel());
    unawaited(_pairSub?.cancel());
    _client?.stop();
    if (host != null) unawaited(host!.stop());
    super.dispose();
  }
}
