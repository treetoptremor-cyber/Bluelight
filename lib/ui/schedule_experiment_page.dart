import 'dart:async';

import 'package:flutter/material.dart';

import '../diagnostics.dart';
import '../hub.dart';
import '../hue_protocol_ext.dart';
import 'common.dart';

/// Developer tool: tries schedule variants on ONE bulb to find out whether
/// a schedule can repeat or leave the light's on/off state alone, which
/// natural light with the app closed would need. It stores a few short-lived
/// "HBX" schedules, waits for them to fire, reads them back and deletes them.
/// Nothing else on the bulb is touched.
class ScheduleExperimentPage extends StatefulWidget {
  const ScheduleExperimentPage({super.key});

  @override
  State<ScheduleExperimentPage> createState() => _ScheduleExperimentPageState();
}

class _Variant {
  const _Variant(
    this.label, {
    this.omitOn = false,
    this.recurrence,
    this.titleFieldDelta = 0,
  });

  final String label;
  final bool omitOn;
  final List<int>? recurrence;
  final int titleFieldDelta;
}

const _noOn = [
  _Variant('no on/off tag, length -3', omitOn: true, titleFieldDelta: -3),
  _Variant('no on/off tag, length same', omitOn: true),
];

const _repeat = [
  _Variant('repeat 7F FF FF FF', recurrence: [0x7F, 0xFF, 0xFF, 0xFF]),
  _Variant('repeat FF FF FF 7F', recurrence: [0xFF, 0xFF, 0xFF, 0x7F]),
  _Variant('repeat 7F 00 00 00', recurrence: [0x7F, 0x00, 0x00, 0x00]),
  _Variant('repeat 01 00 00 00', recurrence: [0x01, 0x00, 0x00, 0x00]),
];

class _ScheduleExperimentPageState extends State<ScheduleExperimentPage> {
  String? _lightId;
  bool _running = false;
  final _log = <String>[];

  void _say(String line) {
    diag('experiment', line);
    if (mounted) setState(() => _log.add(line));
  }

  Future<void> _run(List<_Variant> variants, {required bool offFirst}) async {
    final app = AppScope.of(context);
    final id = _lightId;
    final light = id == null ? null : app.hub.lightOf(id);
    if (light == null) return;
    setState(() {
      _running = true;
      _log.clear();
    });
    final ids = <int, _Variant>{};
    try {
      final wasOn = light.state.on;
      _say('Light is ${wasOn ? 'on' : 'off'}.');
      await light.syncClock();
      final at = DateTime.now().add(const Duration(seconds: 150));
      var n = 0;
      for (final v in variants) {
        n++;
        final sid = await light.createSchedule(
          kind: BulbScheduleKind.wake,
          at: at,
          fade: const Duration(seconds: 2),
          title: 'HBX $n',
          brightness: 120,
          mireds: 350,
          omitOn: v.omitOn,
          recurrence: v.recurrence,
          titleFieldDelta: v.titleFieldDelta,
        );
        _say(
          sid == null
              ? '${v.label}: REFUSED by the bulb'
              : '${v.label}: stored as #$sid',
        );
        if (sid != null) ids[sid] = v;
      }
      if (ids.isEmpty) {
        _say('Nothing was stored. Done.');
        return;
      }
      _say('Waiting for them to fire (about 3 minutes). Keep the app open.');
      await Future<void>.delayed(
        at.difference(DateTime.now()) + const Duration(seconds: 40),
      );
      _say('Light is now ${light.state.on ? 'on' : 'off'}.');
      for (final e in ids.entries) {
        final r = await light.readSchedule(e.key);
        if (r == null) {
          _say('${e.value.label}: gone from the bulb (cleared itself).');
        } else {
          final moved = r.start.difference(
            at.subtract(const Duration(seconds: 2)),
          );
          _say(
            '${e.value.label}: enabled=${r.enabled} ran=${r.ran} '
            'start moved ${moved.inMinutes} min',
          );
        }
      }
    } catch (e) {
      _say('Error: $e');
    } finally {
      for (final sid in ids.keys) {
        try {
          await light.deleteSchedule(sid);
        } catch (_) {}
      }
      _say('Test schedules deleted. Copy the Diagnostics log to share.');
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final lights = [
      for (final l in app.store.lights)
        if (app.hub.lightOf(l.id) != null &&
            app.hub.statusOf(l.id) == LinkStatus.connected)
          l,
    ];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule experiment')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Tests whether a bulb schedule can repeat, or leave the on/off '
            'state alone. It stores a few temporary schedules on one bulb, '
            'waits for them to fire, reads them back and deletes them. The '
            'bulb may turn on and change white briefly.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _lightId,
            decoration: const InputDecoration(labelText: 'Test on this bulb'),
            items: [
              for (final l in lights)
                DropdownMenuItem(value: l.id, child: Text(l.name)),
            ],
            onChanged: _running ? null : (v) => setState(() => _lightId = v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _running || _lightId == null
                ? null
                : () => _run(_noOn, offFirst: true),
            child: const Text(
              'Test A: leave on/off alone (turn the bulb off first)',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _running || _lightId == null
                ? null
                : () => _run(_repeat, offFirst: false),
            child: const Text('Test B: repeat patterns'),
          ),
          const SizedBox(height: 16),
          if (_running) const LinearProgressIndicator(),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}
