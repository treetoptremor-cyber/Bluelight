// Philips Hue Bluetooth protocol: UUIDs, value encoding and a small wrapper
// around a connected bulb.
//
// The protocol is reverse-engineered (see the HueBLE Python library and the
// Home Assistant hue_ble integration). The control characteristics are
// encrypted, so the phone has to be bonded with the bulb.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'color_utils.dart';
import 'diagnostics.dart';
import 'hue_protocol_ext.dart';

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

  /// Combined light state (TLV, with a fade time). See hue_protocol_ext.dart.
  static final combined = Guid('932c32bd-0007-47a2-835a-a8d455b859dd');

  /// On-bulb schedules (wake up / go to sleep).
  static final schedules = Guid('9da2ddf1-0001-44d0-909c-3f3d3cb34a7b');

  /// The bulb's clock: uint32 LE Unix time.
  static final clock = Guid('97fe6561-1001-4f62-86e9-b71ee2da3d22');

  /// Reported to trigger a factory reset when written. Never written: a
  /// reset would remove the bulb from the Hue app.
  static final neverWrite = {Guid('97fe6561-0004-4f62-86e9-b71ee2da3d22')};
}

/// 2200 K: the warmest white many Hue bulbs accept.
const int cappedWarmestMireds = 454;

/// Short name of a Hue characteristic for logs.
String charName(Guid uuid) {
  if (uuid == HueUuids.power) return 'power';
  if (uuid == HueUuids.brightness) return 'brightness';
  if (uuid == HueUuids.temperature) return 'temperature';
  if (uuid == HueUuids.color) return 'colour';
  return uuid.str;
}

String hexBytes(List<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join(' ');

const int minBrightness = 1;
const int maxBrightness = 254;

/// Where the Philips Hue app lets a bulb that is already set up accept a
/// pairing from one more device, without a reset (so the Hue app keeps
/// working). Menu names vary between Hue app versions.
const hueAppDiscoverablePath =
    'Settings → Voice assistants → Amazon Alexa → Make discoverable';

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

/// Whether a device looks like a Hue Bluetooth bulb: it advertises the
/// Signify `fe0f` service, or one of its names contains "hue".
bool looksLikeHueBulb({
  Iterable<Guid> serviceUuids = const [],
  Iterable<Guid> serviceDataUuids = const [],
  Iterable<String> names = const [],
}) {
  if (serviceUuids.contains(HueUuids.advertisedService)) return true;
  if (serviceDataUuids.contains(HueUuids.advertisedService)) return true;
  return names.any((n) => n.toLowerCase().contains('hue'));
}

// ---------------------------------------------------------------------------

/// Whether the bulb is showing a white colour temperature or an xy colour.
enum HueMode { white, color }

/// Snapshot of a bulb's state. [mireds] and [xy] are null when the bulb does
/// not support them (or they have not been read yet). [mode] is our best
/// guess at which of the two the bulb is showing: the bulb doesn't report
/// it, so it follows whichever was written or reported last.
class HueLightState {
  final bool on;
  final int brightness;
  final int? mireds;
  final XyColor? xy;
  final HueMode? mode;

  const HueLightState({
    this.on = false,
    this.brightness = maxBrightness,
    this.mireds,
    this.xy,
    this.mode,
  });

  HueLightState copyWith({
    bool? on,
    int? brightness,
    int? mireds,
    XyColor? xy,
    HueMode? mode,
  }) => HueLightState(
    on: on ?? this.on,
    brightness: brightness ?? this.brightness,
    mireds: mireds ?? this.mireds,
    xy: xy ?? this.xy,
    mode: mode ?? this.mode,
  );

  @override
  bool operator ==(Object other) =>
      other is HueLightState &&
      other.on == on &&
      other.brightness == brightness &&
      other.mireds == mireds &&
      other.xy == xy &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(on, brightness, mireds, xy, mode);

  @override
  String toString() =>
      'HueLightState(on: $on, brightness: $brightness, mireds: $mireds, '
      'xy: $xy, mode: $mode)';
}

/// Guess the mode from a freshly read xy: a clearly saturated colour means
/// colour mode; anything near white is treated as white mode.
HueMode guessMode(XyColor? xy) {
  if (xy == null) return HueMode.white;
  final rgb = xyToRgb(xy.x, xy.y);
  final hi = math.max(rgb.r, math.max(rgb.g, rgb.b));
  final lo = math.min(rgb.r, math.min(rgb.g, rgb.b));
  final saturation = hi <= 0 ? 0.0 : (hi - lo) / hi;
  return saturation > 0.35 ? HueMode.color : HueMode.white;
}

/// Thrown by [HueLight.connect] when its [CancelToken] is cancelled.
class ConnectCancelled implements Exception {
  @override
  String toString() => 'Connection cancelled';
}

/// Lets the caller abandon a [HueLight.connect] that is waiting for the bulb.
class CancelToken {
  final _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  void check() {
    if (isCancelled) throw ConnectCancelled();
  }
}

/// A user-facing explanation of a Bluetooth error, with pairing advice
/// that never involves resetting the bulb (it must keep working in the Hue
/// app).
String describeBleError(Object e) {
  if (e is StateError) return e.message;
  if (e is TimeoutException) {
    return 'Timed out. Is the light powered on and in range?';
  }
  final text = e is FlutterBluePlusException
      ? (e.description ?? 'Bluetooth error ${e.code}')
      : e.toString();
  final lower = text.toLowerCase();
  final pairingFailed =
      (e is FlutterBluePlusException && e.function == 'createBond') ||
      lower.contains('authentication') ||
      lower.contains('encryption');
  if (pairingFailed) {
    return '$text\n\nThe light did not accept pairing with this phone. If it '
        'is set up in the Hue app on another phone, make it discoverable '
        'there ($hueAppDiscoverablePath), then try again within a few '
        'minutes. No reset needed: the Hue app keeps working.';
  }
  return text;
}

/// A Hue Bluetooth bulb, wrapping a [BluetoothDevice].
class HueLight {
  HueLight(this.device);

  final BluetoothDevice device;

  BluetoothCharacteristic? _power;
  BluetoothCharacteristic? _brightness;
  BluetoothCharacteristic? _temperature;
  BluetoothCharacteristic? _color;
  BluetoothCharacteristic? _combined;
  BluetoothCharacteristic? _schedules;
  BluetoothCharacteristic? _clock;
  StreamSubscription<List<int>>? _scheduleSub;
  final _scheduleReplies = StreamController<ScheduleReply>.broadcast();

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

  /// How long a bulb keeps reporting brightness while it fades after being
  /// switched on or off. Brightness reports in this window are ignored and
  /// brightness is read once afterwards.
  static const _fadeTime = Duration(milliseconds: 1500);

  final _quietUntil = <Guid, DateTime>{};
  Timer? _fadeTimer;
  Future<void>? _details;

  /// Completes once notifications are on and the bulb's name has been read,
  /// which [connect] leaves running in the background.
  Future<void> get details => _details ?? Future<void>.value();

  /// Connects, bonds (Android), discovers the light service and reads the
  /// current state. The controls can be shown as soon as this returns;
  /// notifications and the bulb's name follow in the background ([details]).
  ///
  /// With [background], the connection request returns at once and the
  /// phone connects whenever the bulb is in range, for as long as it takes.
  /// flutter_blue_plus runs every Bluetooth operation behind one global
  /// lock, and a normal connect holds it until it succeeds or times out, so
  /// one unplugged bulb would stall every other light. Cancel the wait with
  /// [cancel].
  Future<void> connect({
    void Function(String status)? onStatus,
    bool background = false,
    CancelToken? cancel,
  }) async {
    void status(String s) => onStatus?.call(s);
    final token = cancel ?? CancelToken();

    await _cancelSubscriptions();

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      status('Waiting for Bluetooth…');
      try {
        await FlutterBluePlus.adapterState
            .firstWhere((s) => s == BluetoothAdapterState.on)
            .timeout(const Duration(seconds: 5));
      } on TimeoutException {
        throw StateError('Bluetooth is off. Turn it on and try again.');
      }
    }

    status('Connecting…');
    // No MTU request: every Hue value fits in 4 bytes, and asking costs a
    // round trip on Android.
    if (background) {
      await device.connect(autoConnect: true, mtu: null);
      await Future.any([
        device.connectionState.firstWhere(
          (s) => s == BluetoothConnectionState.connected,
        ),
        token.whenCancelled,
      ]);
    } else {
      await device.connect(timeout: const Duration(seconds: 12), mtu: null);
    }
    token.check();

    if (Platform.isAndroid) {
      status('Pairing… accept the pairing request if Android asks.');
      await device.createBond();
    }

    status('Discovering services…');
    final services = await device.discoverServices(
      subscribeToServicesChanged: false,
    );
    token.check();
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
    _combined = find(HueUuids.combined);
    BluetoothCharacteristic? anywhere(Guid uuid) =>
        [for (final svc in services) ...svc.characteristics]
            .where((c) => c.characteristicUuid == uuid)
            .firstOrNull;
    _schedules = anywhere(HueUuids.schedules);
    _clock = anywhere(HueUuids.clock);
    await _scheduleSub?.cancel();
    _scheduleSub = null;
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
    await _readState(firstTimeout: 60);
    token.check();

    _details = _subscribeAndReadInfo(services);
  }

  /// Turns on notifications (power and brightness first, as they change
  /// most), then reads the name. Never throws: both are nice to have.
  Future<void> _subscribeAndReadInfo(List<BluetoothService> services) async {
    for (final c in [_power, _brightness, _temperature, _color].nonNulls) {
      final sub = c.onValueReceived.listen((v) => _onValue(c, v));
      device.cancelWhenDisconnected(sub);
      _subscriptions.add(sub);
      try {
        await c.setNotifyValue(true);
      } catch (_) {
        // The controls still work without notifications.
      }
    }
    await _readInfo(services);
    _emit(_state); // so listeners pick up the name
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
    final quiet = _quietUntil[uuid];
    if (quiet != null && DateTime.now().isBefore(quiet)) return;
    var s = _state;
    if (uuid == HueUuids.power) {
      s = s.copyWith(on: decodePower(value));
    } else if (uuid == HueUuids.brightness) {
      s = s.copyWith(brightness: decodeBrightness(value));
    } else if (uuid == HueUuids.temperature) {
      s = s.copyWith(mireds: decodeMireds(value), mode: HueMode.white);
    } else if (uuid == HueUuids.color) {
      s = s.copyWith(xy: decodeXy(value), mode: HueMode.color);
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

  /// Writes with response, or without when [fast] and the bulb allows it.
  Future<void> _write(
    BluetoothCharacteristic c,
    List<int> value, {
    bool fast = false,
  }) async {
    if (HueUuids.neverWrite.contains(c.characteristicUuid)) {
      throw StateError('Refusing to write ${c.characteristicUuid}');
    }
    final noResponse = fast && c.properties.writeWithoutResponse;
    try {
      await c.write(value, withoutResponse: noResponse);
    } catch (e) {
      diag(
        'ble',
        '${_tag()} write ${charName(c.characteristicUuid)} '
            '${hexBytes(value)}${noResponse ? ' (no response)' : ''} '
            'failed: $e',
      );
      rethrow;
    }
  }

  Future<List<int>> _read(BluetoothCharacteristic c, {int timeout = 15}) async {
    try {
      return await c.read(timeout: timeout);
    } catch (e) {
      diag(
        'ble',
        '${_tag()} read ${charName(c.characteristicUuid)} failed: $e',
      );
      rethrow;
    }
  }

  String _tag() {
    final id = device.remoteId.str;
    return '$name (${id.length > 8 ? id.substring(0, 8) : id})';
  }

  /// Warmest colour temperature this bulb accepts. Hue bulbs go to 500
  /// mireds (2000 K) or stop at 454 (2200 K); we learn which on the first
  /// refused write.
  int _warmestMireds = maxMireds;
  int get warmestMireds => _warmestMireds;

  Future<void> _readState({int firstTimeout = 15}) async {
    var s = _state.copyWith(
      on: decodePower(
        await _read(_require(_power, 'power'), timeout: firstTimeout),
      ),
      brightness: decodeBrightness(
        await _read(_require(_brightness, 'brightness')),
      ),
    );
    if (_temperature case final t?) {
      s = s.copyWith(mireds: decodeMireds(await _read(t)));
    }
    if (_color case final c?) {
      s = s.copyWith(xy: decodeXy(await _read(c)));
    }
    if (s.mode == null) {
      s = s.copyWith(mode: _color == null ? HueMode.white : guessMode(s.xy));
    }
    _emit(s);
  }

  /// Reads every present characteristic and emits the combined state.
  Future<void> refresh() => _readState();

  Future<void> setPower(bool on) async {
    await _write(_require(_power, 'power'), encodePower(on));
    _emit(_state.copyWith(on: on));
    // The bulb fades, reporting brightness along the way. Ignore that and
    // read the real value once the fade is over.
    _quietUntil[HueUuids.brightness] = DateTime.now().add(_fadeTime);
    _fadeTimer?.cancel();
    _fadeTimer = Timer(_fadeTime, _resyncBrightness);
  }

  Future<void> _resyncBrightness() async {
    final c = _brightness;
    if (c == null || !device.isConnected) return;
    try {
      final b = decodeBrightness(await c.read());
      _emit(_state.copyWith(brightness: b));
    } catch (_) {
      // Next notification will catch up.
    }
  }

  Future<void> setBrightness(int brightness, {bool fast = false}) async {
    final b = brightness.clamp(minBrightness, maxBrightness);
    await _write(
      _require(_brightness, 'brightness'),
      encodeBrightness(b),
      fast: fast,
    );
    _emit(_state.copyWith(brightness: b));
  }

  Future<void> setTemperature(int mireds, {bool fast = false}) async {
    final c = _require(_temperature, 'colour temperature');
    var m = mireds.clamp(minMireds, _warmestMireds);
    try {
      await _write(c, encodeMireds(m), fast: fast);
    } catch (e) {
      // Older bulbs refuse anything warmer than 2200 K (an ATT error).
      if (m <= cappedWarmestMireds || e is! FlutterBluePlusException) rethrow;
      _warmestMireds = cappedWarmestMireds;
      m = cappedWarmestMireds;
      diag('ble', '${_tag()} caps white at 2200 K; retrying');
      await _write(c, encodeMireds(m), fast: fast);
    }
    _emit(_state.copyWith(mireds: m, mode: HueMode.white));
  }

  Future<void> setColor(double x, double y, {bool fast = false}) async {
    await _write(_require(_color, 'colour'), encodeXy(x, y), fast: fast);
    // Report what the bulb actually stores after 16-bit quantisation.
    _emit(_state.copyWith(xy: decodeXy(encodeXy(x, y)), mode: HueMode.color));
  }

  // --- Combined state

  /// Whether the bulb takes combined writes with a fade time.
  bool get supportsTransitions => _combined != null;
  bool _combinedBroken = false;

  /// Sets several things at once, fading over [transition]. Uses the
  /// combined characteristic; falls back to separate writes (without the
  /// fade) if the bulb lacks it or refuses.
  Future<void> setLook({
    bool? on,
    int? brightness,
    int? mireds,
    XyColor? xy,
    Duration? transition,
  }) async {
    final c = _combined;
    if (c != null && !_combinedBroken) {
      final m = mireds?.clamp(minMireds, _warmestMireds);
      try {
        await _write(
          c,
          encodeCombinedState(
            on: on,
            brightness: brightness,
            mireds: m,
            xy: xy,
            transition: transition,
          ),
        );
        var s = _state;
        if (on != null) s = s.copyWith(on: on);
        if (brightness != null) {
          s = s.copyWith(
            brightness: brightness.clamp(minBrightness, maxBrightness),
          );
        }
        if (xy != null) {
          s = s.copyWith(
            xy: decodeXy(encodeXy(xy.x, xy.y)),
            mode: HueMode.color,
          );
        } else if (m != null) {
          s = s.copyWith(mireds: m, mode: HueMode.white);
        }
        _emit(s);
        return;
      } catch (e) {
        _combinedBroken = true;
        diag('ble', '${_tag()} combined write refused; using separate writes');
      }
    }
    if (on == true && !_state.on) await setPower(true);
    if (xy != null && supportsColor) {
      await setColor(xy.x, xy.y);
    } else if (mireds != null && supportsTemperature) {
      await setTemperature(mireds);
    }
    if (brightness != null) await setBrightness(brightness);
    if (on == false) await setPower(false);
  }

  // --- On-bulb schedules

  bool get supportsSchedules => _schedules != null && _clock != null;

  /// Sets the bulb's clock to now. Schedules run on the bulb's clock.
  Future<void> syncClock() async {
    final c = _clock;
    if (c == null) throw StateError('No clock on this bulb');
    await _write(c, buildClockSync(DateTime.now()));
  }

  Future<ScheduleReply> _scheduleCommand(
    List<int> payload,
    bool Function(ScheduleReply r) accept,
  ) async {
    final c = _schedules;
    if (c == null) throw StateError('No schedules on this bulb');
    if (_scheduleSub == null) {
      _scheduleSub = c.onValueReceived.listen((v) {
        final r = ScheduleReply.parse(v);
        diag('sched', '${_tag()} <- ${hexBytes(v)}');
        if (r != null) _scheduleReplies.add(r);
      });
      device.cancelWhenDisconnected(_scheduleSub!);
      await c.setNotifyValue(true);
    }
    final reply = _scheduleReplies.stream
        .firstWhere(accept)
        .timeout(const Duration(seconds: 6));
    diag('sched', '${_tag()} -> ${hexBytes(payload)}');
    await _write(c, payload);
    return reply;
  }

  /// Ids of the schedules stored on the bulb.
  Future<List<int>> listSchedules() async {
    final r = await _scheduleCommand(
      buildScheduleList(),
      (r) => r is ScheduleList,
    );
    return (r as ScheduleList).ids;
  }

  /// Title of a stored schedule, or null if it can't be read.
  Future<String?> scheduleTitle(int id) async {
    final c = _schedules;
    if (c == null) return null;
    final completer = Completer<String?>();
    final sub = c.onValueReceived.listen((v) {
      // Read-back: 02 00 <id_le> <len> 00 00 <body>; the title length sits
      // at body offset 45 and the title follows.
      if (v.length > 8 && v[0] == ScheduleOp.read && v[1] == 0x00) {
        final rid = v[2] | (v[3] << 8);
        if (rid != id || completer.isCompleted) return;
        final body = v.sublist(8);
        const titleLenAt = 48 - 3;
        if (body.length <= titleLenAt) return completer.complete(null);
        final n = body[titleLenAt];
        final end = titleLenAt + 1 + n;
        completer.complete(
          end <= body.length
              ? String.fromCharCodes(body.sublist(titleLenAt + 1, end))
              : null,
        );
      }
    });
    try {
      if (_scheduleSub == null) await listSchedules(); // enables notify
      await _write(c, [ScheduleOp.read, id & 0xFF, id >> 8, 0x00, 0x00]);
      return await completer.future.timeout(const Duration(seconds: 6));
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// Stores a schedule on the bulb. Returns its id, or null if refused.
  Future<int?> createSchedule({
    required BulbScheduleKind kind,
    required DateTime at,
    required Duration fade,
    required String title,
    int brightness = 254,
    int mireds = 447,
  }) async {
    final rnd = math.Random.secure();
    final r = await _scheduleCommand(
      buildSchedulePayload(
        kind: kind,
        at: at,
        fade: fade,
        title: title,
        uuid: [for (var i = 0; i < 16; i++) rnd.nextInt(256)],
        brightness: brightness,
        mireds: mireds.clamp(minMireds, _warmestMireds),
      ),
      (r) => r is ScheduleCreated || r is ScheduleRejected,
    );
    return r is ScheduleCreated ? r.id : null;
  }

  Future<void> deleteSchedule(int id) async {
    await _scheduleCommand(
      buildScheduleDelete(id),
      (r) => r is ScheduleDeleted && r.id == id,
    );
  }

  Future<void> disconnect() async {
    _fadeTimer?.cancel();
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
    _fadeTimer?.cancel();
    await _scheduleSub?.cancel();
    await _scheduleReplies.close();
    await _cancelSubscriptions();
    await _stateController.close();
    try {
      await device.disconnect();
    } catch (_) {
      // Already gone.
    }
  }
}
