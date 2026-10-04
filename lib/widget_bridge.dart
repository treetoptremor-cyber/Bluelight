import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'diagnostics.dart';
import 'hub.dart';
import 'store.dart';
import 'ui/common.dart' show dimmed, stateColor;

/// Publishes the light list to the iOS widgets and Control Center (through
/// the App Group, see ios/Shared/HueShared.swift): favourites first, then
/// groups, then lights. Lights that aren't connected (e.g. while the app is
/// in the background) keep their last known on/off state.
class WidgetBridge {
  WidgetBridge(this.store, this.hub) {
    if (!Platform.isIOS) return;
    store.addListener(_schedule);
    hub.addListener(_schedule);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        onOpen?.call(call.arguments as String);
      }
    });
    _schedule();
  }

  /// Called with a light or group id when a widget is tapped.
  void Function(String id)? onOpen;

  /// Opens a widget tap that launched the app.
  Future<void> openPending() async {
    if (!Platform.isIOS) return;
    try {
      final id = await _channel.invokeMethod<String>('takePendingOpen');
      if (id != null) onOpen?.call(id);
    } catch (e) {
      diag('widgets', 'pending open failed: $e');
    }
  }

  final AppStore store;
  final HueHub hub;
  static const _channel = MethodChannel('hue_ble_remote/widgets');

  final _lastOn = <String, bool>{};
  final _lastColor = <String, String>{};
  Timer? _debounce;
  String? _lastJson;

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _publish);
  }

  static String _hex(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Map<String, Object?> _target(String id, {required bool isGroup}) {
    final lightIds = store.lightIdsFor(id);
    final connected = hub.connected(lightIds);
    if (connected.isNotEmpty) {
      _lastOn[id] = connected.any((l) => l.state.on);
      final lit = connected.where((l) => l.state.on).firstOrNull;
      if (lit != null) {
        _lastColor[id] = _hex(
          dimmed(stateColor(lit.state), lit.state.brightness).toARGB32(),
        );
      }
    }
    return {
      'id': id,
      'name': store.nameOf(id),
      'lights': lightIds,
      'on': _lastOn[id] ?? false,
      'color': _lastColor[id] ?? '#FFB46B',
      'isGroup': isGroup,
    };
  }

  Future<void> _publish() async {
    final ids = <String>[
      ...store.favorites,
      for (final g in store.groups) g.id,
      for (final l in store.lights) l.id,
    ];
    final seen = <String>{};
    final json = jsonEncode({
      'targets': [
        for (final id in ids)
          if (seen.add(id)) _target(id, isGroup: store.group(id) != null),
      ],
      'all': [for (final l in store.lights) l.id],
    });
    if (json == _lastJson) return;
    _lastJson = json;
    try {
      await _channel.invokeMethod<void>('publish', json);
    } catch (e) {
      diag('widgets', 'publish failed: $e');
    }
  }

  void dispose() {
    _debounce?.cancel();
    store.removeListener(_schedule);
    hub.removeListener(_schedule);
  }
}
