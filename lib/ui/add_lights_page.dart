import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../hue_ble.dart';
import '../models.dart';
import 'common.dart';

const _scanTimeout = Duration(seconds: 15);

/// Finds nearby Hue bulbs (plus ones the phone is already connected to or
/// paired with, which may not advertise while the Hue app holds them) and
/// adds the tapped one to the dashboard.
class AddLightsPage extends StatefulWidget {
  const AddLightsPage({super.key});

  @override
  State<AddLightsPage> createState() => _AddLightsPageState();
}

class _Found {
  _Found(this.device, this.name);

  final BluetoothDevice device;
  final String name;
  int? rssi;
  String? status;
}

class _AddLightsPageState extends State<AddLightsPage> {
  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  bool _scanning = false;

  /// In first-seen order, so rows don't jump around as signal changes.
  final _found = <DeviceIdentifier, _Found>{};

  late final StreamSubscription<BluetoothAdapterState> _adapterSub;
  late final StreamSubscription<List<ScanResult>> _resultsSub;
  late final StreamSubscription<bool> _scanningSub;

  @override
  void initState() {
    super.initState();
    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results.where(_isHue)) {
          final f = _found.putIfAbsent(
            r.device.remoteId,
            () => _Found(
              r.device,
              _nameOf([r.advertisementData.advName, r.device.platformName]),
            ),
          );
          f.rssi = r.rssi;
        }
      });
    }, onError: (Object e) => _snack('Scan failed: $e'));
    _scanningSub = FlutterBluePlus.isScanning.listen((s) {
      if (mounted) setState(() => _scanning = s);
    });
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      if (!mounted) return;
      final wasOn = _adapter == BluetoothAdapterState.on;
      setState(() => _adapter = s);
      if (s == BluetoothAdapterState.on && !wasOn) _scan();
    });
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

  Future<void> _scan() async {
    try {
      await FlutterBluePlus.startScan(timeout: _scanTimeout);
    } catch (e) {
      _snack('Could not start scan: $e');
    }
    // After startScan, which asks for the Bluetooth permissions on Android,
    // so the two don't raise overlapping permission requests.
    await _loadKnown();
  }

  /// Hue bulbs this phone is connected to (by any app) or paired with.
  Future<void> _loadKnown() async {
    void add(BluetoothDevice d, String status) {
      final f = _found.putIfAbsent(
        d.remoteId,
        () => _Found(d, _nameOf([d.platformName])),
      );
      f.status ??= status;
    }

    try {
      final connected = await FlutterBluePlus.systemDevices([
        HueUuids.lightService,
      ]);
      for (final d in connected) {
        // iOS filters by service; Android returns every connected device.
        if (Platform.isIOS || looksLikeHueBulb(names: [d.platformName])) {
          add(d, 'Connected to this phone');
        }
      }
    } catch (_) {
      // Rely on the scan.
    }
    if (Platform.isAndroid) {
      try {
        for (final d in await FlutterBluePlus.bondedDevices) {
          if (looksLikeHueBulb(names: [d.platformName])) {
            add(d, 'Paired with this phone');
          }
        }
      } catch (_) {
        // Rely on the scan.
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _add(_Found f) async {
    final store = AppScope.of(context).store;
    await FlutterBluePlus.stopScan();
    await store.addLight(SavedLight(id: f.device.remoteId.str, name: f.name));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${f.name}. If the phone asks to pair, tap Pair.'),
      ),
    );
    Navigator.pop(context);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final on = _adapter == BluetoothAdapterState.on;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add lights'),
        bottom: _scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
        actions: [
          if (on)
            TextButton(
              onPressed: _scanning ? FlutterBluePlus.stopScan : _scan,
              child: Text(_scanning ? 'Stop' : 'Scan'),
            ),
        ],
      ),
      body: on ? _list(context) : _adapterMessage(context),
    );
  }

  Widget _list(BuildContext context) {
    final store = AppScope.of(context).store;
    final theme = Theme.of(context);
    final found = _found.values.toList();
    final hint = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Text(
        'Bulb on and nearby? Bulbs set up in the Hue app on this phone work '
        'as they are. For a bulb set up on another phone, make it '
        'discoverable in the Hue app there first ($hueAppDiscoverablePath). '
        'No reset needed: the Hue app keeps working.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (found.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 48),
          Center(
            child: _scanning
                ? const CircularProgressIndicator()
                : Icon(
                    Icons.lightbulb_outline,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _scanning ? 'Looking for Hue lights…' : 'No Hue lights found.',
            ),
          ),
          hint,
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _scan,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final f in found)
            Builder(
              builder: (context) {
                final added = store.light(f.device.remoteId.str) != null;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.lightbulb_outline),
                    title: Text(f.name),
                    subtitle: f.status == null ? null : Text(f.status!),
                    trailing: added
                        ? const Chip(label: Text('Added'))
                        : _SignalBars(f.rssi),
                    enabled: !added,
                    onTap: added ? null : () => _add(f),
                  ),
                );
              },
            ),
          hint,
        ],
      ),
    );
  }

  Widget _adapterMessage(BuildContext context) {
    final text = switch (_adapter) {
      BluetoothAdapterState.unauthorized =>
        'Bluetooth permission is off. Allow Bluetooth for this app in the '
            'system Settings.',
      BluetoothAdapterState.unknown || BluetoothAdapterState.turningOn => null,
      _ => 'Turn Bluetooth on to find your Hue lights.',
    };
    if (text == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 56),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
            if (Platform.isAndroid &&
                _adapter == BluetoothAdapterState.off) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => FlutterBluePlus.turnOn().catchError(
                  (Object e) => _snack('Could not turn on Bluetooth: $e'),
                ),
                child: const Text('Turn on'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Signal strength as bars instead of a flickering dBm number.
class _SignalBars extends StatelessWidget {
  const _SignalBars(this.rssi);

  final int? rssi;

  @override
  Widget build(BuildContext context) {
    final r = rssi;
    if (r == null) return const SizedBox.shrink();
    final icon = r > -65
        ? Icons.signal_cellular_alt
        : r > -80
        ? Icons.signal_cellular_alt_2_bar
        : Icons.signal_cellular_alt_1_bar;
    return Icon(icon, semanticLabel: '$r dBm');
  }
}
