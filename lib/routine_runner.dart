import 'dart:async';

import 'package:flutter/widgets.dart';

import 'hub.dart';
import 'models.dart';
import 'store.dart';

/// Runs routines at their times while the app is open.
///
/// iOS suspends apps in the background, so routines can't fire while the
/// app is closed; the UI says so. A routine whose lights aren't connected
/// yet is retried on each tick while it is still inside its window.
class RoutineRunner {
  RoutineRunner(this.store, this.hub, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now {
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => check());
    _lifecycle = AppLifecycleListener(onResume: check);
  }

  final AppStore store;
  final HueHub hub;
  final DateTime Function() _now;
  late final Timer _timer;
  late final AppLifecycleListener _lifecycle;

  /// Runs every routine that is due now.
  Future<void> check() async {
    final now = _now();
    for (final r in store.routines) {
      if (!r.isDue(now, lastRun: store.lastRun(r.id))) continue;
      final ids = store.lightIdsFor(r.targetId);
      if (hub.connected(ids).isEmpty) continue; // retry next tick
      await store.markRun(r.id, now);
      await run(r);
    }
  }

  /// Performs [r] now.
  Future<void> run(Routine r) async {
    final fade = Duration(minutes: r.fadeMinutes);
    final ids = store.lightIdsFor(r.targetId);
    try {
      switch (r.action) {
        case RoutineAction.turnOff:
          if (fade > Duration.zero) {
            await hub.fadeOut(r.targetId, fade);
          } else {
            await hub.setPower(ids, false);
          }
        case RoutineAction.turnOn:
          if (fade > Duration.zero) {
            await hub.fadeIn(r.targetId, fade);
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
            await hub.fadeIn(r.targetId, fade, looks: looks);
          } else {
            await hub.applyLooks(looks);
          }
      }
    } catch (_) {
      // Lights that dropped out are skipped; the rest still changed.
    }
  }

  void dispose() {
    _timer.cancel();
    _lifecycle.dispose();
  }
}
