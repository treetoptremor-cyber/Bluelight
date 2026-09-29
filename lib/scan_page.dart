import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'hue_ble.dart';
import 'light_page.dart';

const _scanTimeout = Duration(seconds: 15);

/// Scans for nearby Hue Bluetooth bulbs and lists them.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> _results = [];
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

  static String _nameOf(ScanResult r) {
    for (final n in [r.advertisementData.advName, r.device.platformName]) {
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
  }

  Future<void> _open(ScanResult r) async {
    await FlutterBluePlus.stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LightPage(device: r.device)),
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
    if (_results.isEmpty) {
      return _Message(
        icon: Icons.lightbulb_outline,
        text: _scanning ? 'Looking for Hue lights…' : 'No Hue lights found.',
        hint:
            'Bulb powered on? If it was set up with the Hue Bluetooth '
            'app, reset it there first so it accepts a new pairing.',
      );
    }
    return RefreshIndicator(
      onRefresh: _startScan,
      child: ListView.builder(
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final r = _results[i];
          return ListTile(
            leading: const Icon(Icons.lightbulb),
            title: Text(_nameOf(r)),
            subtitle: Text(r.device.remoteId.str),
            trailing: Text('${r.rssi} dBm'),
            onTap: () => _open(r),
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
