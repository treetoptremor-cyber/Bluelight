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
