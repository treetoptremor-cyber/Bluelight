import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// The user's lights, groups, presets and routines, saved on the phone.
class AppStore extends ChangeNotifier {
  AppStore._(this._prefs);

  static const _key = 'hue_ble_remote.v1';

  final SharedPreferences _prefs;

  List<SavedLight> _lights = [];
  List<LightGroup> _groups = [];
  List<Preset> _presets = [];
  List<Routine> _routines = [];
  Map<String, DateTime> _lastRuns = {};

  List<SavedLight> get lights => List.unmodifiable(_lights);
  List<LightGroup> get groups => List.unmodifiable(_groups);
  List<Preset> get presets => List.unmodifiable(_presets);
  List<Routine> get routines => List.unmodifiable(_routines);

  static Future<AppStore> load() async {
    final store = AppStore._(await SharedPreferences.getInstance());
    store._read();
    return store;
  }

  void _read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      List<Map<String, Object?>> list(String k) => [
        for (final e in (j[k] as List?) ?? const [])
          if (e is Map) e.cast<String, Object?>(),
      ];
      _lights = list('lights').map(SavedLight.fromJson).toList();
      _groups = list('groups').map(LightGroup.fromJson).toList();
      _presets = list('presets').map(Preset.fromJson).toList();
      _routines = list('routines').map(Routine.fromJson).toList();
      _lastRuns = {};
      for (final e in ((j['lastRuns'] as Map?) ?? const {}).entries) {
        final at = e.value is String
            ? DateTime.tryParse(e.value as String)
            : null;
        if (e.key is String && at != null) _lastRuns[e.key as String] = at;
      }
    } catch (_) {
      // Corrupt data: start empty rather than crash.
    }
  }

  Future<void> _save() async {
    notifyListeners();
    await _prefs.setString(
      _key,
      jsonEncode({
        'lights': [for (final l in _lights) l.toJson()],
        'groups': [for (final g in _groups) g.toJson()],
        'presets': [for (final p in _presets) p.toJson()],
        'routines': [for (final r in _routines) r.toJson()],
        'lastRuns': {
          for (final e in _lastRuns.entries) e.key: e.value.toIso8601String(),
        },
      }),
    );
  }

  // --- Lookups

  SavedLight? light(String id) => _lights.where((l) => l.id == id).firstOrNull;
  LightGroup? group(String id) => _groups.where((g) => g.id == id).firstOrNull;
  Preset? preset(String id) => _presets.where((p) => p.id == id).firstOrNull;

  /// The saved lights a light or group id refers to.
  List<String> lightIdsFor(String targetId) {
    final g = group(targetId);
    if (g != null) return g.lightIds.where((id) => light(id) != null).toList();
    return light(targetId) != null ? [targetId] : const [];
  }

  /// Display name of a light or group id.
  String nameOf(String targetId) =>
      group(targetId)?.name ?? light(targetId)?.name ?? 'Deleted';

  List<Preset> presetsFor(String scopeId) =>
      _presets.where((p) => p.scopeId == scopeId).toList();

  DateTime? lastRun(String routineId) => _lastRuns[routineId];

  // --- Lights

  Future<void> addLight(SavedLight light) async {
    _lights = [..._lights.where((l) => l.id != light.id), light];
    await _save();
  }

  Future<void> renameLight(String id, String name) async {
    _lights = [
      for (final l in _lights) l.id == id ? l.copyWith(name: name) : l,
    ];
    await _save();
  }

  /// Removes the light, takes it out of groups and presets, and drops
  /// presets and routines that only targeted it.
  Future<void> removeLight(String id) async {
    _lights = _lights.where((l) => l.id != id).toList();
    _groups = [
      for (final g in _groups)
        g.copyWith(lightIds: g.lightIds.where((l) => l != id).toList()),
    ];
    _presets = [
      for (final p in _presets)
        if (p.scopeId != id)
          Preset(
            id: p.id,
            name: p.name,
            scopeId: p.scopeId,
            looks: Map.of(p.looks)..remove(id),
          ),
    ];
    _routines = _routines.where((r) => r.targetId != id).toList();
    await _save();
  }

  // --- Groups

  Future<void> saveGroup(LightGroup group) async {
    final exists = _groups.any((g) => g.id == group.id);
    _groups = exists
        ? [for (final g in _groups) g.id == group.id ? group : g]
        : [..._groups, group];
    await _save();
  }

  Future<void> removeGroup(String id) async {
    _groups = _groups.where((g) => g.id != id).toList();
    _presets = _presets.where((p) => p.scopeId != id).toList();
    _routines = _routines.where((r) => r.targetId != id).toList();
    await _save();
  }

  // --- Presets

  Future<void> savePreset(Preset preset) async {
    final exists = _presets.any((p) => p.id == preset.id);
    _presets = exists
        ? [for (final p in _presets) p.id == preset.id ? preset : p]
        : [..._presets, preset];
    await _save();
  }

  Future<void> removePreset(String id) async {
    _presets = _presets.where((p) => p.id != id).toList();
    _routines = [
      for (final r in _routines)
        if (r.presetId != id) r,
    ];
    await _save();
  }

  // --- Routines

  Future<void> saveRoutine(Routine routine) async {
    final exists = _routines.any((r) => r.id == routine.id);
    _routines = exists
        ? [for (final r in _routines) r.id == routine.id ? routine : r]
        : [..._routines, routine];
    await _save();
  }

  Future<void> removeRoutine(String id) async {
    _routines = _routines.where((r) => r.id != id).toList();
    _lastRuns.remove(id);
    await _save();
  }

  Future<void> markRun(String routineId, DateTime at) async {
    _lastRuns[routineId] = at;
    await _save();
  }
}
