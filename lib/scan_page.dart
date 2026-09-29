import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'hue_ble.dart';
import 'light_page.dart';

const _scanTimeout = Duration(seconds: 15);

/// Scans for nearby Hue Bluetooth bulbs and lists them, together with Hue
/// bulbs the phone is already connected to or paired with. Those may not be
/// advertising while another app (such as the Hue app) holds a connection.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> _results = [];
  List<_Bulb> _known = [];
  bool _scanning = false;
  bool? _supported;

  late final StreamSubscription<BluetoothAdapterState> _adapterSub;
  late final StreamSubscription<List<ScanResult>> _resultsSub;
  late final StreamSubscription<bool> _scanningSub;

  @override
  void initState() {
    super.initState();
    _checkSupport();
    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _results = results.where(_isHue).toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
      });
    }, onError: (Object e) => _showError('Scan failed: $e'));
    _scanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _scanning = scanning);
    });
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      final wasOn = _adapterState == BluetoothAdapterState.on;
      setState(() => _adapterState = state);
      if (state == BluetoothAdapterState.on && !wasOn) _startScan();
    });
  }

  Future<void> _checkSupport() async {
    final supported = await FlutterBluePlus.isSupported;
    if (mounted) setState(() => _supported = supported);
  }

  @override
  void dispose() {
    _adapterSub.cancel();
    _resultsSub.cancel();
    _scanningSub.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  static bool _isHue(ScanResult r) => looksLikeHueBulb(
    serviceUuids: r.advertisementData.serviceUuids,
    serviceDataUuids: r.advertisementData.serviceData.keys,
    names: [r.advertisementData.advName, r.device.platformName],
  );

  static String _nameOf(List<String> names) {
    for (final n in names) {
      if (n.trim().isNotEmpty) return n.trim();
    }
    return 'Hue light';
  }

  Future<void> _startScan() async {
    try {
      await FlutterBluePlus.startScan(timeout: _scanTimeout);
    } catch (e) {
      _showError('Could not start scan: $e');
    }
    // After startScan, which requests the Bluetooth permissions on Android,
    // so the two don't raise overlapping permission requests.
    await _loadKnownBulbs();
  }

  /// Hue bulbs this phone is connected to (by any app) or paired with.
  /// Best effort: failures here just mean the list relies on the scan.
  Future<void> _loadKnownBulbs() async {
    final known = <_Bulb>[];
    try {
      final connected = await FlutterBluePlus.systemDevices([
        HueUuids.lightService,
      ]);
      for (final d in connected) {
        // iOS filters by service; Android returns every connected device.
        if (Platform.isIOS || looksLikeHueBulb(names: [d.platformName])) {
          known.add(_Bulb(d, _nameOf([d.platformName]), status: 'Connected'));
        }
      }
    } catch (_) {
      // Not available; rely on the scan.
    }
    if (Platform.isAndroid) {
      try {
        for (final d in await FlutterBluePlus.bondedDevices) {
          if (known.any((k) => k.device.remoteId == d.remoteId)) continue;
          if (looksLikeHueBulb(names: [d.platformName])) {
            known.add(_Bulb(d, _nameOf([d.platformName]), status: 'Paired'));
          }
        }
      } catch (_) {
        // Not available; rely on the scan.
      }
    }
    if (mounted) setState(() => _known = known);
  }

  /// Scan results merged with known bulbs, strongest signal first.
  List<_Bulb> get _bulbs {
    final byId = {for (final k in _known) k.device.remoteId: k};
    for (final r in _results) {
      byId[r.device.remoteId] = _Bulb(
        r.device,
        _nameOf([r.advertisementData.advName, r.device.platformName]),
        rssi: r.rssi,
        status: byId[r.device.remoteId]?.status,
      );
    }
    return byId.values.toList()
      ..sort((a, b) => (b.rssi ?? -1000).compareTo(a.rssi ?? -1000));
  }

  Future<void> _open(_Bulb bulb) async {
    await FlutterBluePlus.stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LightPage(device: bulb.device)),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final adapterOn = _adapterState == BluetoothAdapterState.on;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hue lights'),
        bottom: _scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: _body(adapterOn),
      floatingActionButton: adapterOn
          ? FloatingActionButton.extended(
              onPressed: _scanning ? FlutterBluePlus.stopScan : _startScan,
              icon: Icon(_scanning ? Icons.stop : Icons.search),
              label: Text(_scanning ? 'Stop' : 'Scan'),
            )
          : null,
    );
  }

  Widget _body(bool adapterOn) {
    if (_supported == false) {
      return const _Message(
        icon: Icons.bluetooth_disabled,
        text: 'This device does not support Bluetooth Low Energy.',
      );
    }
    if (!adapterOn) return _adapterMessage();
    final bulbs = _bulbs;
    if (bulbs.isEmpty) {
      return _Message(
        icon: Icons.lightbulb_outline,
        text: _scanning ? 'Looking for Hue lights…' : 'No Hue lights found.',
        hint:
            'Bulb powered on and nearby? Bulbs set up in the Hue app on '
            'this phone work here as they are. For a bulb set up on '
            'another phone, make it discoverable in the Hue app there '
            'first ($hueAppDiscoverablePath). No reset needed: the Hue '
            'app keeps working.',
      );
    }
    return RefreshIndicator(
      onRefresh: _startScan,
      child: ListView.builder(
        itemCount: bulbs.length,
        itemBuilder: (context, i) {
          final b = bulbs[i];
          final id = b.device.remoteId.str;
          return ListTile(
            leading: const Icon(Icons.lightbulb),
            title: Text(b.name),
            subtitle: Text(b.status == null ? id : '${b.status} · $id'),
            trailing: b.rssi == null ? null : Text('${b.rssi} dBm'),
            onTap: () => _open(b),
          );
        },
      ),
    );
  }

  Widget _adapterMessage() {
    switch (_adapterState) {
      case BluetoothAdapterState.unauthorized:
        return const _Message(
          icon: Icons.bluetooth_disabled,
          text: 'Bluetooth permission denied.',
          hint: 'Allow Bluetooth for this app in the system Settings.',
        );
      case BluetoothAdapterState.unknown:
      case BluetoothAdapterState.turningOn:
        return const Center(child: CircularProgressIndicator());
      default:
        return _Message(
          icon: Icons.bluetooth_disabled,
          text: 'Turn Bluetooth on to find your Hue lights.',
          action: Platform.isAndroid
              ? FilledButton(
                  onPressed: () => FlutterBluePlus.turnOn().catchError(
                    (Object e) => _showError('Could not turn on Bluetooth: $e'),
                  ),
                  child: const Text('Turn on'),
                )
              : null,
        );
    }
  }
}

/// A row in the bulb list.
class _Bulb {
  const _Bulb(this.device, this.name, {this.rssi, this.status});

  final BluetoothDevice device;
  final String name;

  /// Signal strength, when the bulb was seen in the current scan.
  final int? rssi;

  /// "Connected" or "Paired" for bulbs the phone already knows.
  final String? status;
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              text,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
