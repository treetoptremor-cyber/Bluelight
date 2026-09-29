// Philips Hue Bluetooth protocol: UUIDs, value encoding and a small wrapper
// around a connected bulb.
//
// The protocol is reverse-engineered (see the HueBLE Python library and the
// Home Assistant hue_ble integration). The control characteristics are
// encrypted, so the phone has to be bonded with the bulb.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'color_utils.dart';

/// GATT UUIDs used by Hue Bluetooth bulbs.
abstract final class HueUuids {
  /// 16-bit Signify service UUID (`fe0f`) that Hue bulbs advertise.
  static final advertisedService = Guid('0000fe0f-0000-1000-8000-00805f9b34fb');

  /// Light control service.
  static final lightService = Guid('932c32bd-0000-47a2-835a-a8d455b859dd');

  /// 1 byte: 0x00 off, 0x01 on.
  static final power = Guid('932c32bd-0002-47a2-835a-a8d455b859dd');

  /// 1 byte: 1..254.
  static final brightness = Guid('932c32bd-0003-47a2-835a-a8d455b859dd');

  /// uint16 little-endian, mireds 153..500.
  static final temperature = Guid('932c32bd-0004-47a2-835a-a8d455b859dd');

  /// CIE xy: x and y as uint16 little-endian, each value * 0xFFFF.
  static final color = Guid('932c32bd-0005-47a2-835a-a8d455b859dd');

  /// UTF-8 bulb name (optional).
  static final bulbName = Guid('97fe6561-0003-4f62-86e9-b71ee2da3d22');

  /// Standard Device Information model number string.
  static final modelNumber = Guid('00002a24-0000-1000-8000-00805f9b34fb');
}

const int minBrightness = 1;
const int maxBrightness = 254;

// ---------------------------------------------------------------------------
// Pure encode / decode functions.

List<int> encodePower(bool on) => [on ? 0x01 : 0x00];

/// Returns null for an empty payload.
bool? decodePower(List<int> value) => value.isEmpty ? null : value[0] != 0;

List<int> encodeBrightness(int brightness) => [
  brightness.clamp(minBrightness, maxBrightness),
];

/// Returns null for an empty payload.
int? decodeBrightness(List<int> value) =>
    value.isEmpty ? null : value[0].clamp(minBrightness, maxBrightness);

/// Mireds as uint16 little-endian, clamped to 153..500.
List<int> encodeMireds(int mireds) {
  final m = mireds.clamp(minMireds, maxMireds);
  return [m & 0xFF, (m >> 8) & 0xFF];
}

/// Returns null if the payload is shorter than 2 bytes.
int? decodeMireds(List<int> value) =>
    value.length < 2 ? null : (value[0] & 0xFF) | ((value[1] & 0xFF) << 8);

int _toUint16(double v) => (v.clamp(0.0, 1.0) * 0xFFFF).round();

/// `[x_lo, x_hi, y_lo, y_hi]`, each coordinate scaled to 0..0xFFFF.
List<int> encodeXy(double x, double y) {
  final xi = _toUint16(x);
  final yi = _toUint16(y);
  return [xi & 0xFF, (xi >> 8) & 0xFF, yi & 0xFF, (yi >> 8) & 0xFF];
}

/// Returns null if the payload is shorter than 4 bytes.
XyColor? decodeXy(List<int> value) {
  if (value.length < 4) return null;
  final xi = (value[0] & 0xFF) | ((value[1] & 0xFF) << 8);
  final yi = (value[2] & 0xFF) | ((value[3] & 0xFF) << 8);
  return XyColor(xi / 0xFFFF, yi / 0xFFFF);
}

/// Decodes a UTF-8 string characteristic, dropping trailing NULs.
String decodeString(List<int> value) =>
    utf8.decode(value, allowMalformed: true).replaceAll('\u0000', '').trim();

/// Whether an advertisement looks like a Hue Bluetooth bulb: it advertises
/// the Signify `fe0f` service, or one of its names contains "hue".
bool looksLikeHueBulb({
  required Iterable<Guid> serviceUuids,
  Iterable<Guid> serviceDataUuids = const [],
  Iterable<String> names = const [],
}) {
  if (serviceUuids.contains(HueUuids.advertisedService)) return true;
  if (serviceDataUuids.contains(HueUuids.advertisedService)) return true;
  return names.any((n) => n.toLowerCase().contains('hue'));
}

// ---------------------------------------------------------------------------

/// Snapshot of a bulb's state. [mireds] and [xy] are null when the bulb does
/// not support them (or they have not been read yet).
class HueLightState {
  final bool on;
  final int brightness;
  final int? mireds;
  final XyColor? xy;

  const HueLightState({
    this.on = false,
    this.brightness = maxBrightness,
    this.mireds,
    this.xy,
  });

  HueLightState copyWith({
    bool? on,
    int? brightness,
    int? mireds,
    XyColor? xy,
  }) => HueLightState(
    on: on ?? this.on,
    brightness: brightness ?? this.brightness,
    mireds: mireds ?? this.mireds,
    xy: xy ?? this.xy,
  );

  @override
  bool operator ==(Object other) =>
      other is HueLightState &&
      other.on == on &&
      other.brightness == brightness &&
      other.mireds == mireds &&
      other.xy == xy;

  @override
  int get hashCode => Object.hash(on, brightness, mireds, xy);

  @override
  String toString() =>
      'HueLightState(on: $on, brightness: $brightness, mireds: $mireds, xy: $xy)';
}

/// A Hue Bluetooth bulb, wrapping a [BluetoothDevice].
class HueLight {
  HueLight(this.device);

  final BluetoothDevice device;

  BluetoothCharacteristic? _power;
  BluetoothCharacteristic? _brightness;
  BluetoothCharacteristic? _temperature;
  BluetoothCharacteristic? _color;

  String? _bulbName;
  String? _modelNumber;

  final _subscriptions = <StreamSubscription<List<int>>>[];
  final _stateController = StreamController<HueLightState>.broadcast();
  HueLightState _state = const HueLightState();

  Stream<HueLightState> get stateStream => _stateController.stream;
  HueLightState get state => _state;

  bool get supportsTemperature => _temperature != null;
  bool get supportsColor => _color != null;

  /// Model number from the Device Information service, if readable.
  String? get modelNumber => _modelNumber;

  String get name {
    for (final n in [_bulbName, device.platformName, device.advName]) {
      if (n != null && n.trim().isNotEmpty) return n.trim();
    }
    return 'Hue light';
  }

  /// Connects, bonds (Android), discovers the light service, reads the
  /// current state and subscribes to notifications.
  Future<void> connect({void Function(String status)? onStatus}) async {
    void status(String s) => onStatus?.call(s);

    await _cancelSubscriptions();

    status('Connecting…');
    await device.connect(timeout: const Duration(seconds: 20));

    if (Platform.isAndroid) {
      status('Pairing… accept the pairing request if Android asks.');
      await device.createBond();
    }

    status('Discovering services…');
    final services = await device.discoverServices();
    final light = services
        .where((s) => s.serviceUuid == HueUuids.lightService)
        .firstOrNull;
    if (light == null) {
      throw StateError(
        'This device does not have the Hue light service. '
        'Is it a Hue Bluetooth bulb?',
      );
    }

    BluetoothCharacteristic? find(Guid uuid) => light.characteristics
        .where((c) => c.characteristicUuid == uuid)
        .firstOrNull;
    _power = find(HueUuids.power);
    _brightness = find(HueUuids.brightness);
    _temperature = find(HueUuids.temperature);
    _color = find(HueUuids.color);
    if (_power == null || _brightness == null) {
      throw StateError(
        'The Hue light service is missing the power or brightness '
        'characteristic.',
      );
    }

    // The first read of an encrypted characteristic is what makes iOS show
    // its pairing prompt, so give the user time to accept it.
    status(
      Platform.isIOS
          ? 'Reading light state… if iOS asks to pair, tap Pair.'
          : 'Reading light state…',
    );
    await _power!.read(timeout: 60);
    await refresh();

    await _readInfo(services);

    status('Subscribing to changes…');
    for (final c in [_power, _brightness, _temperature, _color].nonNulls) {
      final sub = c.onValueReceived.listen((v) => _onValue(c, v));
      device.cancelWhenDisconnected(sub);
      _subscriptions.add(sub);
      try {
        await c.setNotifyValue(true);
      } catch (_) {
        // Notifications are nice to have; the controls still work without.
      }
    }
  }

  Future<void> _readInfo(List<BluetoothService> services) async {
    Future<String?> readString(Guid uuid) async {
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.characteristicUuid != uuid) continue;
          try {
            final v = decodeString(await c.read());
            return v.isEmpty ? null : v;
          } catch (_) {
            return null;
          }
        }
      }
      return null;
    }

    _bulbName = await readString(HueUuids.bulbName);
    _modelNumber = await readString(HueUuids.modelNumber);
  }

  void _onValue(BluetoothCharacteristic c, List<int> value) {
    final uuid = c.characteristicUuid;
    var s = _state;
    if (uuid == HueUuids.power) {
      s = s.copyWith(on: decodePower(value));
    } else if (uuid == HueUuids.brightness) {
      s = s.copyWith(brightness: decodeBrightness(value));
    } else if (uuid == HueUuids.temperature) {
      s = s.copyWith(mireds: decodeMireds(value));
    } else if (uuid == HueUuids.color) {
      s = s.copyWith(xy: decodeXy(value));
    }
    _emit(s);
  }

  void _emit(HueLightState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  BluetoothCharacteristic _require(BluetoothCharacteristic? c, String what) {
    if (c == null) throw StateError('This light does not support $what.');
    return c;
  }

  /// Reads every present characteristic and emits the combined state.
  Future<void> refresh() async {
    var s = _state;
    s = s.copyWith(
      on: decodePower(await _require(_power, 'power').read()),
      brightness: decodeBrightness(
        await _require(_brightness, 'brightness').read(),
      ),
    );
    if (_temperature case final t?) {
      s = s.copyWith(mireds: decodeMireds(await t.read()));
    }
    if (_color case final c?) {
      s = s.copyWith(xy: decodeXy(await c.read()));
    }
    _emit(s);
  }

  Future<void> setPower(bool on) async {
    await _require(_power, 'power').write(encodePower(on));
    _emit(_state.copyWith(on: on));
  }

  Future<void> setBrightness(int brightness) async {
    final b = brightness.clamp(minBrightness, maxBrightness);
    await _require(_brightness, 'brightness').write(encodeBrightness(b));
    _emit(_state.copyWith(brightness: b));
  }

  Future<void> setTemperature(int mireds) async {
    final m = mireds.clamp(minMireds, maxMireds);
    await _require(_temperature, 'colour temperature').write(encodeMireds(m));
    _emit(_state.copyWith(mireds: m));
  }

  Future<void> setColor(double x, double y) async {
    await _require(_color, 'colour').write(encodeXy(x, y));
    // Report what the bulb actually stores after 16-bit quantisation.
    _emit(_state.copyWith(xy: decodeXy(encodeXy(x, y))));
  }

  Future<void> disconnect() async {
    await _cancelSubscriptions();
    await device.disconnect();
  }

  Future<void> _cancelSubscriptions() async {
    final subs = List.of(_subscriptions);
    _subscriptions.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }

  /// Cancels subscriptions, closes [stateStream] and disconnects.
  Future<void> dispose() async {
    await _cancelSubscriptions();
    await _stateController.close();
    try {
      await device.disconnect();
    } catch (_) {
      // Already gone.
    }
  }
}
