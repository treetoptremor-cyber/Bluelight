import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'diagnostics.dart';
import 'hue_ble.dart';
import 'hue_protocol_ext.dart';
import 'models.dart';
import 'scenes.dart';
import 'store.dart';

enum LinkStatus {
  /// Not trying (app in the background).
  offline,

  /// Waiting for the light or setting up.
  connecting,

  /// Still waiting after a while: probably off or out of range.
  unreachable,

  /// Ready to control.
  connected,

  /// Setup failed (e.g. pairing refused); retrying with backoff.
  failed,
}

class _Link {
  _Link(this.id, this.light);

  final String id;
  final HueLight light;
  LinkStatus status = LinkStatus.offline;
  String? error;
  CancelToken? token;
  StreamSubscription<HueLightState>? stateSub;
}

/// A brightness ramp on some lights, e.g. a sleep timer or a routine.
class _Fade {
  _Fade({
    required this.lightIds,
    required this.from,
    required this.to,
    required this.duration,
    required this.turnOffAtEnd,
  });

  final List<String> lightIds;
  final Map<String, int> from;
  final Map<String, int> to;
  final Duration duration;
  final bool turnOffAtEnd;
  final started = DateTime.now();
  Timer? timer;

  DateTime get endsAt => started.add(duration);
}

/// Keeps every saved light connected while the app is in the foreground and
/// controls lights, groups and presets.
///
/// Connections use background auto-connect (see [HueLight.connect]) so an
/// unplugged bulb never stalls the others. When the app goes to the
/// background every connection is released, so the Hue app (on this or
/// another phone) can reach the bulbs; they reconnect on return.
class HueHub extends ChangeNotifier {
  HueHub(this.store) {
    store.addListener(_sync);
    _lifecycle = AppLifecycleListener(onPause: _pause, onResume: _resume);
    _sync();
  }

  final AppStore store;
  final _links = <String, _Link>{};
  final _fades = <String, _Fade>{}; // by target id
  late final AppLifecycleListener _lifecycle;
  bool _paused = false;
  bool _disposed = false;

  static const _unreachableAfter = Duration(seconds: 10);

  final _readyListeners = <void Function(String lightId)>[];

  /// Called each time a light is connected and fully set up.
  void onLightReady(void Function(String lightId) listener) =>
      _readyListeners.add(listener);

  /// Sleep timers stored on bulbs: target id -> (light id -> schedule id).
  final _bulbSleep = <String, Map<String, int>>{};
  final _bulbSleepEnds = <String, DateTime>{};

  // --- Queries

  LinkStatus statusOf(String lightId) =>
      _links[lightId]?.status ?? LinkStatus.offline;

  String? errorOf(String lightId) => _links[lightId]?.error;

  HueLight? lightOf(String lightId) => _links[lightId]?.light;

  /// Current state of a connected light, else null.
  HueLightState? stateOf(String lightId) {
    final link = _links[lightId];
    return link?.status == LinkStatus.connected ? link!.light.state : null;
  }

  /// Connected lights among [ids], in order.
  List<HueLight> connected(Iterable<String> ids) => [
    for (final id in ids)
      if (_links[id] case final link? when link.status == LinkStatus.connected)
        link.light,
  ];

  bool anyOn(Iterable<String> ids) => connected(ids).any((l) => l.state.on);

  /// When a fade running on [targetId] ends, or null.
  DateTime? fadeEndsAt(String targetId) {
    final bulb = _bulbSleepEnds[targetId];
    if (bulb != null && bulb.isAfter(DateTime.now())) return bulb;
    return _fades[targetId]?.endsAt;
  }

  /// Current look of each connected light among [ids].
  Map<String, LightLook> snapshot(Iterable<String> ids) => {
    for (final id in ids)
      if (stateOf(id) case final s?) id: LightLook.fromState(s),
  };

  // --- Connections

  void _sync() {
    if (_disposed) return;
    final ids = {for (final l in store.lights) l.id};
    for (final id in _links.keys.toList()) {
      if (!ids.contains(id)) _drop(id);
    }
    for (final id in ids) {
      if (_links.containsKey(id)) continue;
      final link = _Link(id, HueLight(BluetoothDevice.fromId(id)));
      link.stateSub = link.light.stateStream.listen((_) => _notify());
      _links[id] = link;
      if (!_paused) _start(link);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(_Link link, LinkStatus status, {String? error}) {
    if (link.status != status || link.error != error) {
      diag(
        'link',
        '${store.nameOf(link.id)}: ${status.name}'
            '${error == null ? '' : ' - ${error.split('\n').first}'}',
      );
    }
    link.status = status;
    link.error = error;
    _notify();
  }

  void _start(_Link link) {
    link.token?.cancel();
    final token = CancelToken();
    link.token = token;
    _run(link, token);
  }

  Future<void> _run(_Link link, CancelToken token) async {
    var backoff = const Duration(seconds: 2);
    while (!token.isCancelled && !_disposed) {
      _set(link, LinkStatus.connecting);
      final slow = Timer(_unreachableAfter, () {
        if (link.token == token && link.status == LinkStatus.connecting) {
          _set(link, LinkStatus.unreachable);
        }
      });
      try {
        await link.light.connect(background: true, cancel: token);
        slow.cancel();
        backoff = const Duration(seconds: 2);
        _set(link, LinkStatus.connected);
        unawaited(
          link.light.details.then((_) {
            if (link.token != token || _disposed) return;
            for (final l in _readyListeners) {
              l(link.id);
            }
          }),
        );
        await Future.any([
          link.light.device.connectionState.firstWhere(
            (s) => s == BluetoothConnectionState.disconnected,
          ),
          token.whenCancelled,
        ]);
        _cancelFadesFor(link.id);
      } on ConnectCancelled {
        slow.cancel();
        break;
      } catch (e) {
        slow.cancel();
        if (token.isCancelled || _disposed) break;
        _set(link, LinkStatus.failed, error: describeBleError(e));
        await Future.any([Future<void>.delayed(backoff), token.whenCancelled]);
        backoff = Duration(
          milliseconds: math.min(backoff.inMilliseconds * 2, 60000),
        );
      }
    }
  }

  Future<void> _release(_Link link) async {
    link.token?.cancel();
    link.token = null;
    try {
      await link.light.disconnect();
    } catch (_) {
      // Already gone.
    }
  }

  void _drop(String id) {
    final link = _links.remove(id);
    if (link == null) return;
    _cancelFadesFor(id);
    link.token?.cancel();
    link.stateSub?.cancel();
    link.light.dispose();
  }

  void _pause() {
    diag('app', 'background: releasing lights');
    _paused = true;
    for (final f in _fades.values) {
      f.timer?.cancel();
    }
    _fades.clear();
    for (final link in _links.values) {
      _release(link);
      link.status = LinkStatus.offline;
    }
    _notify();
  }

  void _resume() {
    // iOS also reports a resume at launch; only reconnect after a pause.
    if (!_paused) return;
    diag('app', 'foreground: reconnecting lights');
    _paused = false;
    for (final link in _links.values) {
      _start(link);
    }
  }

  /// Retry a light now instead of waiting for the backoff.
  void retry(String lightId) {
    final link = _links[lightId];
    if (link != null && !_paused) _start(link);
  }

  // --- Control. User actions cancel fades on the lights they touch.

  /// Runs [action] on every connected light among [ids] (that passes
  /// [where]) and rethrows the first error once all are done. The writes
  /// still go out one at a time: flutter_blue_plus serialises them.
  Future<void> _each(
    Iterable<String> ids,
    Future<void> Function(String id, HueLight light) action, {
    bool Function(HueLight light)? where,
  }) async {
    Object? error;
    await Future.wait([
      for (final id in ids)
        if (_links[id] case final link?
            when link.status == LinkStatus.connected &&
                (where == null || where(link.light)))
          action(id, link.light).catchError((Object e) {
            error ??= e;
          }),
    ]);
    if (error != null) throw error!;
  }

  Future<void> setPower(Iterable<String> ids, bool on) {
    _cancelFadesOn(ids);
    return _each(ids, (_, l) => l.setPower(on));
  }

  Future<void> setBrightness(
    Iterable<String> ids,
    int brightness, {
    bool fast = false,
  }) {
    _cancelFadesOn(ids);
    return _each(ids, (_, l) => l.setBrightness(brightness, fast: fast));
  }

  Future<void> setTemperature(
    Iterable<String> ids,
    int mireds, {
    bool fast = false,
  }) {
    _cancelFadesOn(ids);
    return _each(
      ids,
      (_, l) => l.setTemperature(mireds, fast: fast),
      where: (l) => l.supportsTemperature,
    );
  }

  Future<void> setColor(
    Iterable<String> ids,
    double x,
    double y, {
    bool fast = false,
  }) {
    _cancelFadesOn(ids);
    return _each(
      ids,
      (_, l) => l.setColor(x, y, fast: fast),
      where: (l) => l.supportsColor,
    );
  }

  /// Sets each light in [looks] to its saved look. Lights that are off get
  /// switched on first so the colour change is visible as a smooth fade.
  Future<void> applyLooks(Map<String, LightLook> looks) {
    _cancelFadesOn(looks.keys);
    return _each(looks.keys, (id, l) => _applyLook(l, looks[id]!));
  }

  /// Applies [scene] across the connected lights among [ids].
  Future<void> applyScene(Iterable<String> ids, HueScene scene) {
    final lights = {
      for (final id in ids)
        if (lightOf(id) case final l? when statusOf(id) == LinkStatus.connected)
          id: LightAbilities(
            color: l.supportsColor,
            white: l.supportsTemperature,
          ),
    };
    return applyLooks(sceneLooks(scene, lights));
  }

  /// One combined write per light where the bulb supports it, with a short
  /// fade so preset changes glide.
  Future<void> _applyLook(HueLight l, LightLook look) async {
    const glide = Duration(milliseconds: 600);
    if (!look.on) {
      await l.setLook(on: false, transition: glide);
      return;
    }
    final color =
        look.mode == HueMode.color && look.xy != null && l.supportsColor;
    await l.setLook(
      on: true,
      brightness: look.brightness,
      xy: color ? look.xy : null,
      mireds: !color && l.supportsTemperature ? look.mireds : null,
      transition: glide,
    );
  }

  // --- Fades

  /// Dims [targetId]'s lights to minimum over [duration], then turns them
  /// off. Used by the sleep timer and "turn off" routines.
  Future<void> fadeOut(
    String targetId,
    Duration duration, {
    List<String>? lightIds,
  }) async {
    await cancelFade(targetId);
    final ids = lightIds ?? store.lightIdsFor(targetId);
    final lit = [
      for (final id in ids)
        if (stateOf(id)?.on ?? false) id,
    ];
    // Prefer the bulbs' own "go to sleep" schedule: it finishes even if the
    // app is closed.
    final onBulb = <String, int>{};
    if (lit.isNotEmpty &&
        lit.every((id) => lightOf(id)!.supportsSchedules) &&
        duration <= maxTransition) {
      final at = DateTime.now().add(const Duration(seconds: 3));
      for (final id in lit) {
        try {
          final light = lightOf(id)!;
          await light.syncClock();
          final sid = await light.createSchedule(
            kind: BulbScheduleKind.sleep,
            at: at,
            fade: duration,
            title: 'HBT Sleep timer',
          );
          if (sid != null) onBulb[id] = sid;
        } catch (e) {
          diag('sched', '${store.nameOf(id)}: sleep timer on bulb failed: $e');
        }
      }
      if (onBulb.length == lit.length) {
        _bulbSleep[targetId] = onBulb;
        _bulbSleepEnds[targetId] = at.add(duration);
        diag('sched', 'sleep timer on bulbs for ${store.nameOf(targetId)}');
        _notify();
        return;
      }
      // Partly failed: undo and fade from the app instead.
      for (final e in onBulb.entries) {
        lightOf(e.key)?.deleteSchedule(e.value).catchError((Object _) {});
      }
    }
    final lights = {for (final id in ids) id: stateOf(id)}
      ..removeWhere((_, s) => s == null || !s.on);
    if (lights.isEmpty) return;
    _startFade(
      targetId,
      _Fade(
        lightIds: lights.keys.toList(),
        from: {for (final e in lights.entries) e.key: e.value!.brightness},
        to: {for (final id in lights.keys) id: minBrightness},
        duration: duration,
        turnOffAtEnd: true,
      ),
    );
  }

  /// Brings [targetId]'s lights up to [looks] (or their current look, turned
  /// on) starting from minimum brightness, over [duration]. Used by
  /// "wake up" style routines.
  Future<void> fadeIn(
    String targetId,
    Duration duration, {
    Map<String, LightLook>? looks,
    List<String>? lightIds,
  }) async {
    final ids = lightIds ?? store.lightIdsFor(targetId);
    final targets = <String, LightLook>{};
    for (final id in ids) {
      final look = looks?[id] ?? _onLook(id);
      if (look != null) targets[id] = look;
    }
    if (targets.isEmpty) return;
    // Start dim, in the target colour, then ramp brightness.
    await applyLooks({
      for (final e in targets.entries)
        e.key: LightLook(
          on: true,
          brightness: minBrightness,
          mode: e.value.mode,
          mireds: e.value.mireds,
          xy: e.value.xy,
        ),
    });
    _startFade(
      targetId,
      _Fade(
        lightIds: targets.keys.toList(),
        from: {for (final id in targets.keys) id: minBrightness},
        to: {for (final e in targets.entries) e.key: e.value.brightness},
        duration: duration,
        turnOffAtEnd: false,
      ),
    );
  }

  LightLook? _onLook(String id) {
    final s = stateOf(id);
    if (s == null) return null;
    final look = LightLook.fromState(s);
    return LightLook(
      on: true,
      brightness: s.on ? s.brightness : maxBrightness,
      mode: look.mode,
      mireds: look.mireds,
      xy: look.xy,
    );
  }

  void _startFade(String targetId, _Fade fade) {
    _cancelFadesOn(fade.lightIds);
    _fades[targetId] = fade;
    final last = <String, int>{};
    void tick() {
      final t =
          (DateTime.now().difference(fade.started).inMilliseconds /
                  math.max(1, fade.duration.inMilliseconds))
              .clamp(0.0, 1.0);
      for (final id in fade.lightIds) {
        final from = fade.from[id]!;
        final to = fade.to[id]!;
        final b = (from + (to - from) * t).round();
        final light = connected([id]).firstOrNull;
        if (light == null || last[id] == b) continue;
        last[id] = b;
        light.setBrightness(b).catchError((Object _) {});
      }
      if (t >= 1) {
        fade.timer?.cancel();
        _fades.remove(targetId);
        if (fade.turnOffAtEnd) {
          for (final l in connected(fade.lightIds)) {
            l.setPower(false).catchError((Object _) {});
          }
        }
        _notify();
      }
    }

    fade.timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    tick();
    _notify();
  }

  Future<void> cancelFade(String targetId) async {
    _fades.remove(targetId)?.timer?.cancel();
    _bulbSleepEnds.remove(targetId);
    final onBulb = _bulbSleep.remove(targetId);
    _notify();
    for (final e in (onBulb ?? const <String, int>{}).entries) {
      try {
        await lightOf(e.key)?.deleteSchedule(e.value);
      } catch (_) {
        // Already ran or the light is gone.
      }
    }
  }

  void _cancelFadesOn(Iterable<String> lightIds) {
    final ids = lightIds.toSet();
    final hit = [
      for (final e in _fades.entries)
        if (e.value.lightIds.any(ids.contains)) e.key,
    ];
    for (final key in hit) {
      _fades.remove(key)?.timer?.cancel();
    }
    if (hit.isNotEmpty) _notify();
  }

  void _cancelFadesFor(String lightId) => _cancelFadesOn([lightId]);

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_sync);
    _lifecycle.dispose();
    for (final f in _fades.values) {
      f.timer?.cancel();
    }
    for (final id in _links.keys.toList()) {
      _drop(id);
    }
    super.dispose();
  }
}
