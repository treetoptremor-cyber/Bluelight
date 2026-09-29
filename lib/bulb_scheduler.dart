import 'dart:async';

import 'diagnostics.dart';
import 'hub.dart';
import 'hue_ble.dart';
import 'hue_protocol_ext.dart';
import 'models.dart';
import 'store.dart';

/// One schedule to store on a bulb.
class PlannedSchedule {
  const PlannedSchedule({
    required this.routineId,
    required this.at,
    required this.kind,
    required this.fade,
    required this.title,
    this.brightness = maxBrightness,
    this.mireds = 366,
  });

  final String routineId;

  /// The routine's set time for this occurrence.
  final DateTime at;
  final BulbScheduleKind kind;
  final Duration fade;
  final String title;
  final int brightness;
  final int mireds;
}

/// Mirrors routines onto the bulbs' own schedules, so they run with the app
/// closed (and the phone away). The bulb only runs a schedule once, so the
/// next [occurrences] of each routine are stored, and topped up whenever
/// the app connects to the bulb or a routine changes.
///
/// Routines a bulb can't run itself (colour presets) stay with the in-app
/// [RoutineRunner]. Only schedules whose title starts with [titlePrefix] are
/// ever removed; the Hue app's own schedules are left alone.
class BulbScheduler {
  BulbScheduler(this.store, this.hub) {
    hub.onLightReady(_onLightReady);
    store.addListener(_onStoreChanged);
  }

  final AppStore store;
  final HueHub hub;

  static const titlePrefix = 'HBR ';
  static const occurrences = 3;

  /// Keys of occurrences stored on a bulb: `routine|light|epochMinutes`.
  final _armed = <String>{};
  final _busy = <String>{};
  final _again = <String>{};
  Timer? _debounce;

  static String _key(String routineId, String lightId, DateTime at) =>
      '$routineId|$lightId|${at.millisecondsSinceEpoch ~/ 60000}';

  /// Whether [lightId]'s bulb will run [routineId]'s occurrence at [at]
  /// itself, so the in-app runner should leave that light alone.
  bool isArmed(String routineId, String lightId, DateTime at) =>
      _armed.contains(_key(routineId, lightId, at));

  /// Number of routine occurrences stored on [lightId]'s bulb.
  int armedCount(String lightId) =>
      _armed.where((k) => k.contains('|$lightId|')).length;

  void _onLightReady(String lightId) => arm(lightId);

  void _onStoreChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      for (final l in store.lights) {
        if (hub.statusOf(l.id) == LinkStatus.connected) arm(l.id);
      }
    });
  }

  /// What [lightId]'s bulb should run, from now on.
  static List<PlannedSchedule> plan({
    required AppStore store,
    required String lightId,
    required HueLight light,
    required DateTime now,
  }) {
    final out = <PlannedSchedule>[];
    for (final r in store.routines) {
      if (!r.enabled || !store.lightIdsFor(r.targetId).contains(lightId)) {
        continue;
      }
      final fade = Duration(minutes: r.fadeMinutes);
      BulbScheduleKind kind;
      var brightness = maxBrightness;
      var mireds = light.state.mireds ?? 366;
      switch (r.action) {
        case RoutineAction.turnOff:
          kind = BulbScheduleKind.sleep;
        case RoutineAction.turnOn:
          kind = BulbScheduleKind.wake;
        case RoutineAction.preset:
          final look = r.presetId == null
              ? null
              : store.preset(r.presetId!)?.looks[lightId];
          if (look == null) continue;
          if (!look.on) {
            kind = BulbScheduleKind.sleep;
          } else if (look.mode == HueMode.color && light.supportsColor) {
            continue; // colour isn't in the bulb's schedule format
          } else {
            kind = BulbScheduleKind.wake;
            brightness = look.brightness;
            mireds = look.mireds ?? mireds;
          }
      }
      final title = '$titlePrefix${r.name}';
      for (final at in r.upcoming(now, occurrences)) {
        // The bulb needs the start in the future (wake stores fade start).
        if (!r.startFor(at).isAfter(now.add(const Duration(seconds: 30)))) {
          continue;
        }
        out.add(
          PlannedSchedule(
            routineId: r.id,
            at: at,
            kind: kind,
            fade: fade,
            title: title,
            brightness: brightness,
            mireds: mireds,
          ),
        );
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// Replaces this app's schedules on [lightId]'s bulb with the current plan.
  Future<void> arm(String lightId) async {
    if (_busy.contains(lightId)) {
      _again.add(lightId);
      return;
    }
    final light = hub.lightOf(lightId);
    if (light == null ||
        hub.statusOf(lightId) != LinkStatus.connected ||
        !light.supportsSchedules) {
      return;
    }
    _busy.add(lightId);
    final name = store.nameOf(lightId);
    try {
      await light.syncClock();
      for (final id in await light.listSchedules()) {
        final title = await light.scheduleTitle(id);
        if (title != null && title.startsWith(titlePrefix)) {
          await light.deleteSchedule(id);
        }
      }
      _armed.removeWhere((k) => k.contains('|$lightId|'));
      final planned = plan(
        store: store,
        lightId: lightId,
        light: light,
        now: DateTime.now(),
      );
      var stored = 0;
      for (final p in planned) {
        final id = await light.createSchedule(
          kind: p.kind,
          at: p.at,
          fade: p.fade,
          title: p.title,
          brightness: p.brightness,
          mireds: p.mireds,
        );
        if (id == null) {
          diag('sched', '$name refused a schedule (full?); stored $stored');
          break;
        }
        _armed.add(_key(p.routineId, lightId, p.at));
        stored++;
      }
      diag('sched', '$name: ${planned.length} planned, $stored stored on bulb');
    } catch (e) {
      diag('sched', '$name: arming failed: $e');
    } finally {
      _busy.remove(lightId);
      if (_again.remove(lightId)) unawaited(arm(lightId));
    }
  }

  void dispose() {
    _debounce?.cancel();
    store.removeListener(_onStoreChanged);
  }
}
