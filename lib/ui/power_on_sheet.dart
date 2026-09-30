import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../hub.dart';
import '../hue_ble.dart';
import '../hue_protocol_ext.dart';
import 'common.dart';

/// Lets the user pick what [lightIds] do when power comes back, e.g. after
/// a wall switch or a power cut.
Future<void> showPowerOnSheet(BuildContext context, List<String> lightIds) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PowerOnSheet(lightIds),
    );

class _Option {
  const _Option(this.label, this.detail, this.state, this.icon);

  final String label;
  final String detail;
  final PowerOnState state;
  final IconData icon;
}

class _PowerOnSheet extends StatefulWidget {
  const _PowerOnSheet(this.lightIds);

  final List<String> lightIds;

  @override
  State<_PowerOnSheet> createState() => _PowerOnSheetState();
}

class _PowerOnSheetState extends State<_PowerOnSheet> {
  PowerOnState? _current;
  bool _loading = true;
  bool _saving = false;

  HueHub get _hub => AppScope.of(context).hub;

  List<HueLight> get _lights => [
    for (final l in _hub.connected(widget.lightIds))
      if (l.supportsPowerOn) l,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final first = _lights.firstOrNull;
    PowerOnState? current;
    try {
      current = await first?.readPowerOn();
    } catch (_) {
      // Shown as unknown.
    }
    if (mounted) {
      setState(() {
        _current = current;
        _loading = false;
      });
    }
  }

  List<_Option> _options() {
    final s = _lights.firstOrNull?.state;
    return [
      const _Option(
        'Hue default',
        'On, bright warm white',
        PowerOnState(on: true, brightness: 254, mireds: 366),
        Icons.lightbulb,
      ),
      const _Option(
        'Soft warm',
        'On, dimmed candle-warm white',
        PowerOnState(on: true, brightness: 100, mireds: 447),
        Icons.nightlight_outlined,
      ),
      const _Option(
        'Stay off',
        'Stays off until you switch it on in the app',
        PowerOnState(on: false),
        Icons.power_settings_new,
      ),
      if (s != null)
        _Option(
          'Current look',
          'On, the way it looks right now',
          PowerOnState(
            on: true,
            brightness: s.brightness,
            mireds: s.mireds ?? 366,
            xy: s.mode == HueMode.color ? s.xy : null,
          ),
          Icons.palette_outlined,
        ),
    ];
  }

  bool _matches(PowerOnState a, PowerOnState? b) {
    if (b == null || a.on != b.on) return false;
    if (!a.on) return true;
    if ((a.xy == null) != (b.xy == null)) return false;
    if (a.xy != null) {
      return (a.xy!.x - b.xy!.x).abs() < 0.002 &&
          (a.xy!.y - b.xy!.y).abs() < 0.002 &&
          (a.brightness - b.brightness).abs() <= 2;
    }
    return (a.brightness - b.brightness).abs() <= 2 &&
        (a.mireds - b.mireds).abs() <= 2;
  }

  Future<void> _apply(PowerOnState state) async {
    setState(() => _saving = true);
    Object? error;
    for (final l in _lights) {
      try {
        await l.writePowerOn(state);
      } catch (e) {
        error ??= e;
      }
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (error == null) _current = state;
    });
    if (error != null) showError(context, error);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lights = _lights;
    final c = _current;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(
                'When power comes back',
                style: theme.textTheme.titleLarge,
              ),
              subtitle: Text(
                lights.isEmpty
                    ? 'Connect the light first.'
                    : 'After a wall switch or power cut'
                          '${lights.length > 1 ? ' · applies to ${lights.length} lights' : ''}.',
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (lights.isNotEmpty)
              for (final o in _options())
                ListTile(
                  leading: Icon(o.icon),
                  title: Text(o.label),
                  subtitle: Text(o.detail),
                  trailing: _matches(o.state, c)
                      ? Icon(
                          Icons.check_circle,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  enabled: !_saving,
                  onTap: () => _apply(o.state),
                ),
            if (!_loading &&
                c != null &&
                !_options().any((o) => _matches(o.state, c)))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  c.on
                      ? 'Now: on at ${(c.brightness / maxBrightness * 100).round()}%'
                            '${c.xy == null ? ', ${miredsToKelvin(c.mireds)} K' : ', a colour'}'
                      : 'Now: stays off',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_saving) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
