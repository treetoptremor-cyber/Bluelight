import 'dart:async';

import 'package:flutter/widgets.dart';

import 'diagnostics.dart';
import 'bulb_scheduler.dart';
import 'hub.dart';
import 'models.dart';
import 'store.dart';

/// Runs routines at their times while the app is open.
///
/// iOS suspends apps in the background, so routines can't fire while the
/// app is closed; the UI says so. A routine whose lights aren't connected
/// yet is retried on each tick while it is still inside its window.
///
/// Lights whose bulb stores the occurrence itself ([BulbScheduler]) are left
/// to the bulb, so nothing runs twice.
class RoutineRunner {
  RoutineRunner(
    this.store,
    this.hub, {
    this.scheduler,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => check());
    _lifecycle = AppLifecycleListener(onResume: check);
  }

  final AppStore store;
  final HueHub hub;
  final BulbScheduler? scheduler;
  final DateTime Function() _now;
  late final Timer _timer;
  late final AppLifecycleListener _lifecycle;

  /// Runs every routine that is due now.
  Future<void> check() async {
    final now = _now();
    for (final r in store.routines) {
      final at = r.dueOccurrence(now, lastRun: store.lastRun(r.id));
      if (at == null) continue;
      final ids = [
        for (final id in store.lightIdsFor(r.targetId))
          if (!(scheduler?.isArmed(r.id, id, at) ?? false)) id,
      ];
      if (ids.isEmpty) {
        await store.markRun(r.id, now); // the bulbs run it themselves
        continue;
      }
      if (hub.connected(ids).isEmpty) continue; // retry next tick
      await store.markRun(r.id, now);
      await run(r, lightIds: ids);
    }
  }

  /// Performs [r] now, on [lightIds] (default: all its lights).
  Future<void> run(Routine r, {List<String>? lightIds}) async {
    diag('routine', 'running "${r.name}" on ${store.nameOf(r.targetId)}');
    final fade = Duration(minutes: r.fadeMinutes);
    final ids = lightIds ?? store.lightIdsFor(r.targetId);
    try {
      switch (r.action) {
        case RoutineAction.turnOff:
          if (fade > Duration.zero) {
            await hub.fadeOut(r.targetId, fade, lightIds: ids);
          } else {
            await hub.setPower(ids, false);
          }
        case RoutineAction.turnOn:
          if (fade > Duration.zero) {
            await hub.fadeIn(r.targetId, fade, lightIds: ids);
          } else {
            await hub.setPower(ids, true);
          }
        case RoutineAction.preset:
          final preset = r.presetId == null ? null : store.preset(r.presetId!);
          if (preset == null) return;
          final looks = {
            for (final e in preset.looks.entries)
              if (ids.contains(e.key)) e.key: e.value,
          };
          final anyOn = looks.values.any((l) => l.on);
          if (fade > Duration.zero && anyOn) {
            await hub.fadeIn(r.targetId, fade, looks: looks, lightIds: ids);
          } else {
            await hub.applyLooks(looks);
          }
      }
    } catch (e) {
      // Lights that dropped out are skipped; the rest still changed.
      diag('routine', '"${r.name}" partly failed: $e');
    }
  }

  void dispose() {
    _timer.cancel();
    _lifecycle.dispose();
  }
}
