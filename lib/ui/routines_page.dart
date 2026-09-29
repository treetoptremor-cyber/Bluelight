import 'package:flutter/material.dart';

import '../hue_ble.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';

const _dayLetters = {1: 'M', 2: 'T', 3: 'W', 4: 'T', 5: 'F', 6: 'S', 7: 'S'};
const _dayNames = {
  1: 'Mon',
  2: 'Tue',
  3: 'Wed',
  4: 'Thu',
  5: 'Fri',
  6: 'Sat',
  7: 'Sun',
};

String _daysLabel(Set<int> days) {
  if (days.length == 7) return 'Every day';
  if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) return 'Weekdays';
  if (days.length == 2 && days.containsAll({6, 7})) return 'Weekends';
  return [for (final d in days.toList()..sort()) _dayNames[d]].join(', ');
}

String _actionLabel(AppStore store, Routine r) {
  final what = switch (r.action) {
    RoutineAction.turnOn => 'Turn on',
    RoutineAction.turnOff => 'Turn off',
    RoutineAction.preset =>
      'Preset "${r.presetId == null ? '?' : store.preset(r.presetId!)?.name ?? 'deleted'}"',
  };
  final fade = r.fadeMinutes == 0 ? '' : ', fade ${r.fadeMinutes} min';
  return '$what$fade';
}

/// Whether [r] applies a colour preset, which bulbs can't store.
bool _needsApp(AppStore store, Routine r) {
  if (r.action != RoutineAction.preset || r.presetId == null) return false;
  final p = store.preset(r.presetId!);
  return p != null &&
      p.looks.values.any((l) => l.on && l.mode == HueMode.color);
}

/// Lists routines.
class RoutinesPage extends StatelessWidget {
  const RoutinesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('Routines')),
          floatingActionButton: store.lights.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RoutineEditPage(),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('New routine'),
                ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Stored on your lights'),
                  subtitle: Text(
                    'Routines are saved on the bulbs themselves, so they run '
                    'with the app closed and your phone away. Each bulb holds '
                    'the next few runs; opening the app tops them up, so '
                    'open it at least every couple of days. Colour presets '
                    'can only run while the app is open.',
                  ),
                ),
              ),
              if (store.routines.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    store.lights.isEmpty
                        ? 'Add lights first.'
                        : 'No routines yet. Try a slow wake-up or an evening '
                              'wind-down.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final r in store.routines)
                Card(
                  child: ListTile(
                    title: Text(
                      '${TimeOfDay(hour: r.minuteOfDay ~/ 60, minute: r.minuteOfDay % 60).format(context)} · ${r.name}',
                    ),
                    subtitle: Text(
                      '${_daysLabel(r.weekdays)} · ${store.nameOf(r.targetId)}\n'
                      '${_actionLabel(store, r)}'
                      '${_needsApp(store, r) ? ' · needs the app open' : ''}',
                    ),
                    isThreeLine: true,
                    trailing: Switch(
                      value: r.enabled,
                      onChanged: (v) =>
                          store.saveRoutine(r.copyWith(enabled: v)),
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RoutineEditPage(routineId: r.id),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Create or edit a routine.
class RoutineEditPage extends StatefulWidget {
  const RoutineEditPage({super.key, this.routineId});

  final String? routineId;

  @override
  State<RoutineEditPage> createState() => _RoutineEditPageState();
}

class _RoutineEditPageState extends State<RoutineEditPage> {
  final _name = TextEditingController();
  String? _target;
  TimeOfDay _time = const TimeOfDay(hour: 7, minute: 0);
  Set<int> _days = {...Routine.allWeek};
  RoutineAction _action = RoutineAction.turnOn;
  String? _presetId;
  int _fade = 0;
  bool _enabled = true;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final store = AppScope.of(context).store;
    final r = widget.routineId == null
        ? null
        : store.routines.where((r) => r.id == widget.routineId).firstOrNull;
    if (r != null) {
      _name.text = r.name;
      _target = r.targetId;
      _time = TimeOfDay(hour: r.minuteOfDay ~/ 60, minute: r.minuteOfDay % 60);
      _days = {...r.weekdays};
      _action = r.action;
      _presetId = r.presetId;
      _fade = r.fadeMinutes;
      _enabled = r.enabled;
    } else {
      _target = store.groups.firstOrNull?.id ?? store.lights.firstOrNull?.id;
    }
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Routine? _build(AppStore store) {
    final target = _target;
    if (target == null || _days.isEmpty) return null;
    if (_action == RoutineAction.preset &&
        store.preset(_presetId ?? '') == null) {
      return null;
    }
    final name = _name.text.trim();
    return Routine(
      id: widget.routineId ?? newId('r'),
      name: name.isEmpty ? _defaultName() : name,
      targetId: target,
      minuteOfDay: _time.hour * 60 + _time.minute,
      weekdays: _days,
      action: _action,
      presetId: _action == RoutineAction.preset ? _presetId : null,
      fadeMinutes: _fade,
      enabled: _enabled,
    );
  }

  String _defaultName() => switch (_action) {
    RoutineAction.turnOn => _fade > 0 ? 'Wake up' : 'Lights on',
    RoutineAction.turnOff => _fade > 0 ? 'Wind down' : 'Lights off',
    RoutineAction.preset => 'Preset',
  };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.store;
    final theme = Theme.of(context);
    final routine = _build(store);
    final presets = _target == null ? <Preset>[] : store.presetsFor(_target!);
    if (_presetId != null && !presets.any((p) => p.id == _presetId)) {
      _presetId = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.routineId == null ? 'New routine' : 'Edit routine'),
        actions: [
          TextButton(
            onPressed: routine == null
                ? null
                : () async {
                    await store.saveRoutine(routine);
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: _defaultName(),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _target,
            decoration: const InputDecoration(
              labelText: 'Lights',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final g in store.groups)
                DropdownMenuItem(value: g.id, child: Text('${g.name} (group)')),
              for (final l in store.lights)
                DropdownMenuItem(value: l.id, child: Text(l.name)),
            ],
            onChanged: (v) => setState(() => _target = v),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Time'),
            trailing: Text(
              _time.format(context),
              style: theme.textTheme.headlineSmall,
            ),
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: _time,
              );
              if (t != null) setState(() => _time = t);
            },
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final d in _dayLetters.keys)
                FilterChip(
                  showCheckmark: false,
                  label: Text(_dayLetters[d]!),
                  tooltip: _dayNames[d],
                  selected: _days.contains(d),
                  onSelected: (v) => setState(() {
                    v ? _days.add(d) : _days.remove(d);
                  }),
                ),
            ],
          ),
          if (_days.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Pick at least one day.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),
          SegmentedButton<RoutineAction>(
            segments: const [
              ButtonSegment(
                value: RoutineAction.turnOn,
                label: Text('Turn on'),
                icon: Icon(Icons.wb_sunny_outlined),
              ),
              ButtonSegment(
                value: RoutineAction.preset,
                label: Text('Preset'),
                icon: Icon(Icons.palette_outlined),
              ),
              ButtonSegment(
                value: RoutineAction.turnOff,
                label: Text('Turn off'),
                icon: Icon(Icons.bedtime_outlined),
              ),
            ],
            selected: {_action},
            onSelectionChanged: (s) => setState(() => _action = s.first),
          ),
          if (_action == RoutineAction.preset) ...[
            const SizedBox(height: 16),
            if (presets.isEmpty)
              Text(
                'No presets saved for these lights yet. Open them, set the '
                'look you want, and tap "Save current look".',
                style: theme.textTheme.bodyMedium,
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _presetId,
                decoration: const InputDecoration(
                  labelText: 'Preset',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in presets)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => setState(() => _presetId = v),
              ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _fade,
            decoration: InputDecoration(
              labelText: _action == RoutineAction.turnOff
                  ? 'Fade out over (starts at the set time)'
                  : 'Fade in over (done by the set time)',
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final m in const [0, 1, 5, 10, 15, 20, 30, 45, 60])
                DropdownMenuItem(
                  value: m,
                  child: Text(m == 0 ? 'Instantly' : '$m minutes'),
                ),
            ],
            onChanged: (v) => setState(() => _fade = v ?? 0),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: routine == null
                ? null
                : () async {
                    await app.runner.run(routine);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Ran "${routine.name}"')),
                      );
                    }
                  },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run now'),
          ),
          if (widget.routineId != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete routine?',
                  message: 'This routine will no longer run.',
                  action: 'Delete',
                );
                if (!ok) return;
                await store.removeRoutine(widget.routineId!);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete routine'),
            ),
          ],
        ],
      ),
    );
  }
}
