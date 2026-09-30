import 'dart:async';

import 'package:flutter/foundation.dart';

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
class BulbScheduler extends ChangeNotifier {
  BulbScheduler(this.store, this.hub) {
    hub.onLightReady(enqueue);
    store.addListener(_onStoreChanged);
  }

  final AppStore store;
  final HueHub hub;

  static const titlePrefix = 'HBR ';
  static const occurrences = 3;

  /// The bulb needs a schedule's start a little in the future.
  static const minLead = Duration(seconds: 5);

  /// Keys of occurrences stored on a bulb: `routine|light|epochMinutes`.
  final _armed = <String>{};

  /// Ids of the schedules this app stored on each bulb (this session), so
  /// they can be removed without reading every schedule's title back.
  final _ourIds = <String, List<int>>{};

  /// Lights waiting to be synced, one at a time so each finishes quickly.
  final _queue = <String>[];
  bool _running = false;
  Completer<void>? _idle;
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

  /// Lights holding [routineId]'s next occurrence.
  int lightsArmedFor(String routineId) => {
    for (final k in _armed)
      if (k.startsWith('$routineId|')) k.split('|')[1],
  }.length;

  /// Whether a sync is in progress or queued.
  bool get syncing => _running || _queue.isNotEmpty;

  /// Completes when nothing is left to sync (or after [timeout]).
  Future<void> idle({Duration timeout = const Duration(seconds: 25)}) {
    if (!syncing) return Future.value();
    _idle ??= Completer<void>();
    return _idle!.future.timeout(timeout, onTimeout: () {});
  }

  void _onStoreChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      // Lights targeted by routines first, so they're ready soonest.
      final targeted = {
        for (final r in store.routines) ...store.lightIdsFor(r.targetId),
      };
      final ids = [
        ...store.lights.map((l) => l.id).where(targeted.contains),
        ...store.lights.map((l) => l.id).where((id) => !targeted.contains(id)),
      ];
      for (final id in ids) {
        if (hub.statusOf(id) == LinkStatus.connected) enqueue(id);
      }
    });
  }

  /// Queues [lightId] for a sync (once).
  void enqueue(String lightId) {
    if (!_queue.contains(lightId)) _queue.add(lightId);
    notifyListeners();
    if (!_running) _drain();
  }

  Future<void> _drain() async {
    _running = true;
    while (_queue.isNotEmpty) {
      await arm(_queue.removeAt(0));
      notifyListeners();
    }
    _running = false;
    notifyListeners();
    _idle?.complete();
    _idle = null;
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
        if (!r.startFor(at).isAfter(now.add(minLead))) {
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
  /// Replaces this app's schedules on [lightId]'s bulb with the current
  /// plan. Prefer [enqueue]; this runs immediately.
  Future<void> arm(String lightId) async {
    final light = hub.lightOf(lightId);
    if (light == null ||
        hub.statusOf(lightId) != LinkStatus.connected ||
        !light.supportsSchedules) {
      return;
    }
    final name = store.nameOf(lightId);
    final watch = Stopwatch()..start();
    try {
      await light.syncClock();
      final known = _ourIds[lightId];
      final onBulb = await light.listSchedules();
      // Ours from this session are known by id; otherwise (after a restart)
      // read titles back to find them.
      for (final id in onBulb) {
        final ours = known != null
            ? known.contains(id)
            : (await light.scheduleTitle(id))?.startsWith(titlePrefix) ?? false;
        if (ours) await light.deleteSchedule(id);
      }
      _armed.removeWhere((k) => k.contains('|$lightId|'));
      final planned = plan(
        store: store,
        lightId: lightId,
        light: light,
        now: DateTime.now(),
      );
      final created = <int>[];
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
          diag('sched', '$name refused a schedule (full?)');
          break;
        }
        created.add(id);
        _armed.add(_key(p.routineId, lightId, p.at));
      }
      _ourIds[lightId] = created;
      diag(
        'sched',
        '$name: ${planned.length} planned, ${created.length} stored '
            'in ${watch.elapsedMilliseconds} ms',
      );
    } catch (e) {
      diag('sched', '$name: sync failed: $e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
