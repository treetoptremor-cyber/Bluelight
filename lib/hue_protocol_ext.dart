// Extended Hue Bluetooth protocol: the combined light-state characteristic
// (with a fade time) and on-bulb schedules with clock sync.
//
// Sources (community reverse engineering, not official):
// - Combined state TLV: flip-dots/HueBLE (UUID_EFFECTS, PR #16).
// - Schedules and clock: captures by luigibrancati,
//   https://gist.github.com/luigibrancati/47442f40adf6f54b17337d8dd3794e2c
//   (byte layout reproduced from its build_standard_schedule_payload).
//
// Pure Dart: encoders and decoders only, no Bluetooth calls.

import 'dart:typed_data';

import 'color_utils.dart';

/// Tags of the combined light-state TLV (`[tag][len][value LE]`).
abstract final class StateTag {
  static const on = 0x01;
  static const brightness = 0x02;
  static const mireds = 0x03;
  static const xy = 0x04;

  /// Transition time, uint16 in 100 ms units.
  static const transition = 0x05;

  /// Effect id (see [HueEffect]); 0 = none.
  static const effect = 0x06;

  /// Effect speed 0..255.
  static const effectSpeed = 0x08;
}

/// Built-in bulb effects (ids from flip-dots/HueBLE). Which ones a bulb
/// runs depends on its model and firmware.
enum HueEffect {
  none(0x00, 'None'),
  candle(0x01, 'Candle'),
  fireplace(0x02, 'Fireplace'),
  prism(0x03, 'Prism'),
  sunrise(0x09, 'Sunrise'),
  sparkle(0x0A, 'Sparkle'),
  opal(0x0B, 'Opal'),
  glisten(0x0C, 'Glisten'),
  sunset(0x0D, 'Sunset'),
  underwater(0x0E, 'Underwater'),
  cosmos(0x0F, 'Cosmos'),
  sunbeam(0x10, 'Sunbeam'),
  enchant(0x11, 'Enchant');

  const HueEffect(this.id, this.label);

  final int id;
  final String label;

  static HueEffect fromId(int id) =>
      values.where((e) => e.id == id).firstOrNull ?? none;
}

/// Splits a `[tag][len][value]` sequence. Stops at the first malformed
/// entry. Later duplicates win.
Map<int, List<int>> decodeTlv(List<int> data) {
  final out = <int, List<int>>{};
  var i = 0;
  while (i + 2 <= data.length) {
    final tag = data[i];
    final len = data[i + 1];
    if (i + 2 + len > data.length) break;
    out[tag] = data.sublist(i + 2, i + 2 + len);
    i += 2 + len;
  }
  return out;
}

/// The effect a combined-state notification reports, if it carries one.
/// Notifications are 10/12 bytes without an effect and 16/18 with one;
/// they are TLV sequences, so the effect tag is looked up directly.
HueEffect? decodeCombinedEffect(List<int> data) {
  final v = decodeTlv(data)[StateTag.effect];
  return v == null || v.isEmpty ? null : HueEffect.fromId(v[0]);
}

/// What a bulb does when power comes back (e.g. after a wall switch).
class PowerOnState {
  const PowerOnState({
    required this.on,
    this.brightness = 254,
    this.mireds = 366,
    this.xy,
  });

  final bool on;
  final int brightness;
  final int mireds;

  /// Colour to come on in; null means the white [mireds].
  final XyColor? xy;

  @override
  bool operator ==(Object other) =>
      other is PowerOnState &&
      other.on == on &&
      other.brightness == brightness &&
      other.mireds == mireds &&
      other.xy == xy;

  @override
  int get hashCode => Object.hash(on, brightness, mireds, xy);

  @override
  String toString() =>
      'PowerOnState(on: $on, brightness: $brightness, mireds: $mireds, xy: $xy)';
}

/// Encodes a power-on state for the startup characteristic: on, brightness,
/// white, and xy, where xy `FF FF FF FF` means "use the white instead".
List<int> encodePowerOn(PowerOnState s) {
  final white = [StateTag.xy, 4, 0xFF, 0xFF, 0xFF, 0xFF];
  return [
    ...encodeCombinedState(
      on: s.on,
      brightness: s.brightness,
      mireds: s.mireds,
      xy: s.xy,
    ),
    if (s.xy == null) ...white,
  ];
}

/// Decodes the startup characteristic, or null if it isn't understood.
PowerOnState? decodePowerOn(List<int> data) {
  final t = decodeTlv(data);
  final on = t[StateTag.on];
  if (on == null || on.isEmpty) return null;
  final b = t[StateTag.brightness];
  final m = t[StateTag.mireds];
  final xy = t[StateTag.xy];
  final isWhite = xy == null || xy.length != 4 || xy.every((v) => v == 0xFF);
  return PowerOnState(
    on: on[0] != 0,
    brightness: b == null || b.isEmpty ? 254 : b[0].clamp(1, 254),
    mireds: m == null || m.length < 2 ? 366 : (m[0] | (m[1] << 8)),
    xy: isWhite
        ? null
        : XyColor(
            (xy[0] | (xy[1] << 8)) / 0xFFFF,
            (xy[2] | (xy[3] << 8)) / 0xFFFF,
          ),
  );
}

/// Longest fade a single write can carry (uint16 of 100 ms units).
const maxTransition = Duration(milliseconds: 0xFFFF * 100);

int _u16(double v) => (v.clamp(0.0, 1.0) * 0xFFFF).round();

/// Encodes a combined light-state write. Only the given fields are sent;
/// [transition] makes the bulb fade to them over that time.
List<int> encodeCombinedState({
  bool? on,
  int? brightness,
  int? mireds,
  XyColor? xy,
  Duration? transition,
  HueEffect? effect,
  int? effectSpeed,
}) {
  final out = <int>[];
  if (on != null) out.addAll([StateTag.on, 1, on ? 1 : 0]);
  if (brightness != null) {
    out.addAll([StateTag.brightness, 1, brightness.clamp(1, 254)]);
  }
  if (mireds != null) {
    final m = mireds.clamp(minMireds, maxMireds);
    out.addAll([StateTag.mireds, 2, m & 0xFF, m >> 8]);
  }
  if (xy != null) {
    final x = _u16(xy.x);
    final y = _u16(xy.y);
    out.addAll([StateTag.xy, 4, x & 0xFF, x >> 8, y & 0xFF, y >> 8]);
  }
  if (transition != null) {
    final t = (transition.inMilliseconds / 100).round().clamp(0, 0xFFFF);
    out.addAll([StateTag.transition, 2, t & 0xFF, t >> 8]);
  }
  if (effect != null) out.addAll([StateTag.effect, 1, effect.id]);
  if (effectSpeed != null) {
    out.addAll([StateTag.effectSpeed, 1, effectSpeed.clamp(0, 255)]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Schedules

/// Opcodes on the schedule characteristic.
abstract final class ScheduleOp {
  static const list = 0x00;
  static const write = 0x01;
  static const read = 0x02;
  static const delete = 0x03;
  static const done = 0x04;
}

/// What an on-bulb schedule does. [wake] fades in from dark to
/// [brightness]/[mireds], finishing at the scheduled time; [sleep] fades out
/// from the scheduled time and then switches off.
enum BulbScheduleKind { wake, sleep }

const _createSourceId = 0xFFFF;
const _titleFieldBase = 0x0118;
const _recurrenceNone = [0xFF, 0xFF, 0xFF, 0xFF];

/// Builds a create payload for an on-bulb schedule, following the captured
/// layout exactly:
///
/// ```
/// 01 | source id u16 (FFFF = new) | 00 | enabled | 00 | start time u32
/// | 00 0e  01 01 on  02 01 bri  03 02 mireds  05 02 fade
/// | titleBase+len u16 | uuid[16] | lightsOff | FF FF FF FF
/// | titleLen | title | enabled
/// ```
///
/// [at] is when the schedule "happens": for [BulbScheduleKind.wake] the fade
/// ends then (the bulb stores the fade start), for sleep it starts then.
/// Titles must be ASCII; other characters are dropped.
Uint8List buildSchedulePayload({
  required BulbScheduleKind kind,
  required DateTime at,
  required Duration fade,
  required String title,
  required List<int> uuid,
  int brightness = 254,
  int mireds = 447,
  bool enabled = true,
  int sourceId = _createSourceId,
}) {
  if (uuid.length != 16) throw ArgumentError.value(uuid, 'uuid', '16 bytes');
  final fadeDs = (fade.inMilliseconds / 100).round();
  if (fadeDs < 0 || fadeDs > 0xFFFF) {
    throw ArgumentError.value(fade, 'fade', 'must be 0..~109 minutes');
  }
  final titleBytes = [
    for (final c in title.codeUnits)
      if (c >= 0x20 && c < 0x7F) c,
  ].take(40).toList();

  final wake = kind == BulbScheduleKind.wake;
  final start = wake ? at.subtract(fade) : at;
  final t = start.toUtc().millisecondsSinceEpoch ~/ 1000;

  // The light state the schedule moves to. Sleep keeps the captured values.
  final b = wake ? brightness.clamp(1, 254) : 0x01;
  final m = wake ? mireds.clamp(minMireds, maxMireds) : 0x024c;
  final state = [
    0x00, 0x0e, //
    StateTag.on, 1, wake ? 1 : 0,
    StateTag.brightness, 1, b,
    StateTag.mireds, 2, m & 0xFF, m >> 8,
    StateTag.transition, 2, fadeDs & 0xFF, fadeDs >> 8,
  ];
  final titleField = _titleFieldBase + titleBytes.length;

  return Uint8List.fromList([
    ScheduleOp.write,
    sourceId & 0xFF, sourceId >> 8,
    0x00, enabled ? 1 : 0, 0x00,
    t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF, (t >> 24) & 0xFF,
    ...state,
    titleField & 0xFF, titleField >> 8,
    ...uuid,
    wake ? 0x00 : 0x01, // sleep: lights off at the end
    ..._recurrenceNone,
    titleBytes.length,
    ...titleBytes,
    enabled ? 1 : 0,
  ]);
}

Uint8List buildScheduleDelete(int id) =>
    Uint8List.fromList([ScheduleOp.delete, id & 0xFF, id >> 8]);

Uint8List buildScheduleList() => Uint8List.fromList([ScheduleOp.list]);

/// uint32 little-endian Unix time (UTC seconds) for the clock characteristic.
Uint8List buildClockSync(DateTime now) {
  final t = now.toUtc().millisecondsSinceEpoch ~/ 1000;
  return Uint8List.fromList([
    t & 0xFF,
    (t >> 8) & 0xFF,
    (t >> 16) & 0xFF,
    (t >> 24) & 0xFF,
  ]);
}

/// A decoded notification from the schedule characteristic.
sealed class ScheduleReply {
  const ScheduleReply();

  static ScheduleReply? parse(List<int> d) {
    int u16(int i) => d[i] | (d[i + 1] << 8);
    if (d.length == 6 && d[0] == ScheduleOp.write && d[1] == 0x00) {
      return ScheduleCreated(u16(4));
    }
    if (d.length >= 2 && d[0] == ScheduleOp.write && d[1] == 0x01) {
      return const ScheduleRejected();
    }
    if (d.length == 4 && d[0] == ScheduleOp.delete && d[1] == 0x00) {
      return ScheduleDeleted(u16(2));
    }
    if (d.length >= 4 && d[0] == ScheduleOp.list && d[1] == 0x00) {
      final count = d[3];
      if (d.length < 4 + count * 2) return null;
      return ScheduleList([for (var i = 0; i < count; i++) u16(4 + i * 2)]);
    }
    if (d.length == 5 && d[0] == ScheduleOp.done) return ScheduleDone(u16(3));
    return null;
  }
}

class ScheduleCreated extends ScheduleReply {
  const ScheduleCreated(this.id);
  final int id;
}

class ScheduleRejected extends ScheduleReply {
  const ScheduleRejected();
}

class ScheduleDeleted extends ScheduleReply {
  const ScheduleDeleted(this.id);
  final int id;
}

class ScheduleList extends ScheduleReply {
  const ScheduleList(this.ids);
  final List<int> ids;
}

class ScheduleDone extends ScheduleReply {
  const ScheduleDone(this.id);
  final int id;
}

/// A schedule as stored on a bulb (from a read-back).
class StoredSchedule {
  const StoredSchedule({
    required this.id,
    required this.title,
    required this.start,
    required this.wake,
    required this.fade,
    required this.enabled,
    this.ran = false,
  });

  /// The bulb marks a schedule as run (and disables it) once it fires.
  final bool ran;

  final int id;
  final String title;

  /// When the bulb starts acting: a wake schedule's fade start, a sleep
  /// schedule's set time.
  final DateTime start;

  /// Wake (fade in, switch on) vs sleep (fade out, switch off).
  final bool wake;
  final Duration fade;
  final bool enabled;

  /// A wake schedule's set time (fade finished).
  DateTime get at => wake ? start.add(fade) : start;
}

/// Parses a `02 00 <id> <len> .. .. .. <body>` read-back notification. The
/// body is the create payload from its 4th byte on, so write-payload offset
/// k is body offset k-3.
StoredSchedule? parseScheduleReadback(List<int> v) {
  if (v.length < 8 || v[0] != ScheduleOp.read || v[1] != 0x00) return null;
  final id = v[2] | (v[3] << 8);
  final len = v[4];
  if (v.length < 8 + len) return null;
  final body = v.sublist(8, 8 + len);
  int at(int payloadOffset) => body[payloadOffset - 3];
  if (body.length < 50 - 3) return null;
  final t = at(6) | (at(7) << 8) | (at(8) << 16) | (at(9) << 24);
  final fadeDs = at(24) | (at(25) << 8);
  // Both layouts end `<title length> <title> <enabled>`, but read-backs
  // seem one byte shorter than create payloads before the title (the
  // reference decoder reads it at 48, the builder writes it at 49), so find
  // the title from the end.
  var title = '';
  for (var n = 0; n <= 64 && n + 2 <= body.length; n++) {
    final p = body.length - 2 - n;
    if (body[p] != n) continue;
    final chars = body.sublist(p + 1, p + 1 + n);
    if (chars.every((c) => c >= 0x20 && c < 0x7F)) {
      title = String.fromCharCodes(chars);
      break;
    }
  }
  return StoredSchedule(
    id: id,
    title: title,
    start: DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true).toLocal(),
    wake: at(14) == 0x01,
    fade: Duration(milliseconds: fadeDs * 100),
    enabled: at(4) == 0x01,
    ran: at(5) == 0x01,
  );
}
