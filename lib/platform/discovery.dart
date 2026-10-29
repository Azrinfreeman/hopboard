import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../core/protocol.dart';

class LanInterface {
  LanInterface(this.name, this.address);
  final String name;
  final String address;
  static Future<List<LanInterface>> list() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && isLocalAddress(address.address))
            LanInterface(interface.name, address.address),
    ];
  }
}

class NearbyHost {
  NearbyHost(this.id, this.name, this.address, this.port);
  final String id;
  final String name;
  final String address;
  final int port;
}

class LanDiscovery {
  BonsoirDiscovery? _discovery;
  BonsoirBroadcast? _broadcast;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  final hosts = <String, NearbyHost>{};
  void Function()? onChange;

  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    _discovery = discovery;
    try {
      await discovery.initialize();
    } catch (_) {
      _discovery = null;
      rethrow;
    }
    _subscription = discovery.eventStream!.listen((event) {
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        event.service.resolve(discovery.serviceResolver);
      } else if (event is BonsoirDiscoveryServiceResolvedEvent ||
          event is BonsoirDiscoveryServiceUpdatedEvent) {
        final service = event.service;
        if (service == null) return;
        final id = service.attributes['id'];
        final addresses = service.hostAddresses.where(
          (address) => isLocalAddress(address),
        );
        if (id != null &&
            addresses.isNotEmpty &&
            service.attributes['v'] == '1') {
          hosts[id] = NearbyHost(
            id,
            service.name,
            addresses.first,
            service.port,
          );
          onChange?.call();
        }
      } else if (event is BonsoirDiscoveryServiceLostEvent) {
        hosts.removeWhere((_, host) => host.name == event.service.name);
        onChange?.call();
      }
    }, onError: (Object _) {});
    try {
      await discovery.start();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      _discovery = null;
      rethrow;
    }
  }

  Future<void> advertise(
    String id,
    String name,
    String address,
    int port,
  ) async {
    await stopAdvertising();
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: name,
        type: serviceType,
        port: port,
        hostAddresses: [address],
        attributes: {'id': id, 'v': '1'},
      ),
      printLogs: false,
    );
    _broadcast = broadcast;
    await broadcast.initialize();
    await broadcast.start();
  }

  Future<void> stopAdvertising() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null) await broadcast.stop();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) await discovery.stop();
    await stopAdvertising();
    hosts.clear();
  }
}
