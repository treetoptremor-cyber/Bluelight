// Saved app data: lights, groups, presets and routines. Plain Dart with
// JSON round trips; persisted by AppStore.

import 'dart:math' as math;

import 'color_utils.dart';
import 'hue_ble.dart';

final _random = math.Random();

/// A short unique id with a readable prefix, e.g. `g_lq3x9a_4f2`.
String newId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '_${_random.nextInt(1 << 20).toRadixString(36)}';

/// How one light looks: what a preset stores per light.
class LightLook {
  final bool on;
  final int brightness;
  final HueMode mode;
  final int? mireds;
  final XyColor? xy;

  const LightLook({
    required this.on,
    required this.brightness,
    this.mode = HueMode.white,
    this.mireds,
    this.xy,
  });

  factory LightLook.fromState(HueLightState s) => LightLook(
    on: s.on,
    brightness: s.brightness,
    mode: s.mode ?? HueMode.white,
    mireds: s.mireds,
    xy: s.xy,
  );

  Map<String, Object?> toJson() => {
    'on': on,
    'brightness': brightness,
    'mode': mode.name,
    if (mireds != null) 'mireds': mireds,
    if (xy != null) 'x': xy!.x,
    if (xy != null) 'y': xy!.y,
  };

  factory LightLook.fromJson(Map<String, Object?> j) => LightLook(
    on: j['on'] as bool? ?? true,
    brightness: (j['brightness'] as num?)?.toInt() ?? maxBrightness,
    mode: HueMode.values.asNameMap()[j['mode']] ?? HueMode.white,
    mireds: (j['mireds'] as num?)?.toInt(),
    xy: j['x'] is num && j['y'] is num
        ? XyColor((j['x'] as num).toDouble(), (j['y'] as num).toDouble())
        : null,
  );

  @override
  bool operator ==(Object other) =>
      other is LightLook &&
      other.on == on &&
      other.brightness == brightness &&
      other.mode == mode &&
      other.mireds == mireds &&
      other.xy == xy;

  @override
  int get hashCode => Object.hash(on, brightness, mode, mireds, xy);
}

/// A light the user added to the dashboard. [id] is the Bluetooth remote id.
class SavedLight {
  final String id;
  final String name;

  const SavedLight({required this.id, required this.name});

  SavedLight copyWith({String? name}) =>
      SavedLight(id: id, name: name ?? this.name);

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory SavedLight.fromJson(Map<String, Object?> j) =>
      SavedLight(id: j['id'] as String, name: j['name'] as String? ?? '');
}

/// Lights controlled together. A light can be in several groups.
class LightGroup {
  final String id;
  final String name;
  final List<String> lightIds;

  const LightGroup({
    required this.id,
    required this.name,
    required this.lightIds,
  });

  LightGroup copyWith({String? name, List<String>? lightIds}) => LightGroup(
    id: id,
    name: name ?? this.name,
    lightIds: lightIds ?? this.lightIds,
  );

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'lights': lightIds};

  factory LightGroup.fromJson(Map<String, Object?> j) => LightGroup(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    lightIds: [...?(j['lights'] as List?)?.whereType<String>()],
  );
}

/// A saved look for a light or group: one [LightLook] per light. [scopeId]
/// is the light or group it was saved from, so it is listed there.
class Preset {
  final String id;
  final String name;
  final String scopeId;
  final Map<String, LightLook> looks;

  const Preset({
    required this.id,
    required this.name,
    required this.scopeId,
    required this.looks,
  });

  Preset copyWith({String? name}) =>
      Preset(id: id, name: name ?? this.name, scopeId: scopeId, looks: looks);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'scope': scopeId,
    'looks': {for (final e in looks.entries) e.key: e.value.toJson()},
  };

  factory Preset.fromJson(Map<String, Object?> j) => Preset(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    scopeId: j['scope'] as String? ?? '',
    looks: {
      for (final e in ((j['looks'] as Map?) ?? const {}).entries)
        if (e.key is String && e.value is Map)
          e.key as String: LightLook.fromJson(
            (e.value as Map).cast<String, Object?>(),
          ),
    },
  );
}

enum RoutineAction { preset, turnOn, turnOff }

/// Something to do to a light or group at a time of day on chosen weekdays.
class Routine {
  final String id;
  final String name;

  /// A light id or group id.
  final String targetId;

  /// Minutes after midnight, local time.
  final int minuteOfDay;

  /// [DateTime.monday] .. [DateTime.sunday].
  final Set<int> weekdays;

  final RoutineAction action;
  final String? presetId;

  /// Fade in or out over this many minutes; 0 means instantly.
  final int fadeMinutes;
  final bool enabled;

  const Routine({
    required this.id,
    required this.name,
    required this.targetId,
    required this.minuteOfDay,
    required this.weekdays,
    required this.action,
    this.presetId,
    this.fadeMinutes = 0,
    this.enabled = true,
  });

  static const allWeek = {1, 2, 3, 4, 5, 6, 7};

  Routine copyWith({
    String? name,
    String? targetId,
    int? minuteOfDay,
    Set<int>? weekdays,
    RoutineAction? action,
    String? presetId,
    int? fadeMinutes,
    bool? enabled,
  }) => Routine(
    id: id,
    name: name ?? this.name,
    targetId: targetId ?? this.targetId,
    minuteOfDay: minuteOfDay ?? this.minuteOfDay,
    weekdays: weekdays ?? this.weekdays,
    action: action ?? this.action,
    presetId: presetId ?? this.presetId,
    fadeMinutes: fadeMinutes ?? this.fadeMinutes,
    enabled: enabled ?? this.enabled,
  );

  /// When this routine is scheduled on the day of [day].
  DateTime _at(DateTime day) => DateTime(
    day.year,
    day.month,
    day.day,
    minuteOfDay ~/ 60,
    minuteOfDay % 60,
  );

  /// Whether the routine should run at [now]: it is enabled, scheduled
  /// today, its time passed less than [window] ago, and it hasn't run since.
  /// The window stops a routine from firing long after its time just
  /// because the app was opened late.
  bool isDue(
    DateTime now, {
    DateTime? lastRun,
    Duration window = const Duration(minutes: 2),
  }) {
    if (!enabled || !weekdays.contains(now.weekday)) return false;
    final at = _at(now);
    if (now.isBefore(at) || now.difference(at) >= window) return false;
    return lastRun == null || lastRun.isBefore(at);
  }

  /// The next time this routine is scheduled strictly after [now], or null
  /// if it never runs.
  DateTime? nextRun(DateTime now) {
    if (!enabled || weekdays.isEmpty) return null;
    for (var i = 0; i <= 7; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      if (!weekdays.contains(day.weekday)) continue;
      final at = _at(day);
      if (at.isAfter(now)) return at;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'target': targetId,
    'minute': minuteOfDay,
    'days': weekdays.toList()..sort(),
    'action': action.name,
    if (presetId != null) 'preset': presetId,
    'fade': fadeMinutes,
    'enabled': enabled,
  };

  factory Routine.fromJson(Map<String, Object?> j) => Routine(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    targetId: j['target'] as String? ?? '',
    minuteOfDay: ((j['minute'] as num?)?.toInt() ?? 0).clamp(0, 24 * 60 - 1),
    weekdays: {...?(j['days'] as List?)?.whereType<num>().map((d) => d.toInt())}
        .where((d) => d >= 1 && d <= 7)
        .toSet(),
    action:
        RoutineAction.values.asNameMap()[j['action']] ?? RoutineAction.turnOn,
    presetId: j['preset'] as String?,
    fadeMinutes: ((j['fade'] as num?)?.toInt() ?? 0).clamp(0, 120),
    enabled: j['enabled'] as bool? ?? true,
  );
}
