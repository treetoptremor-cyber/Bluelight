import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../color_utils.dart';
import '../hub.dart';
import '../hue_ble.dart';
import '../hue_protocol_ext.dart';
import '../natural_light.dart';
import '../models.dart';
import '../paced_value.dart';
import '../store.dart';
import 'common.dart';
import 'info_sheets.dart';
import 'scenes_page.dart';
import '../scenes_data.dart';

/// 2200 K, the warmest white every Hue bulb accepts (some stop there).
const _minKelvin = 2200.0;
const _maxKelvin = 6500.0;

typedef HueSat = ({double hue, double sat});

/// White-balance notches on the White slider.
const _whiteNotches = <(String, double)>[
  ('Candle', 2200), // candlelight, a cosy restaurant
  ('Warm', 2700), // warm indoor
  ('Neutral', 3500), // neutral indoor
  ('Daylight', 5500),
];

const _swatches = <Color>[
  Color(0xFFFF2A00),
  Color(0xFFFF8000),
  Color(0xFFFFD000),
  Color(0xFF30FF30),
  Color(0xFF00D8FF),
  Color(0xFF2040FF),
  Color(0xFFA020FF),
  Color(0xFFFF40A0),
];

/// Controls for one light or a group ([targetId] is either).
class TargetPage extends StatefulWidget {
  const TargetPage({super.key, required this.targetId});

  final String targetId;

  @override
  State<TargetPage> createState() => _TargetPageState();
}

class _TargetPageState extends State<TargetPage> {
  late final AppScope _app = AppScope.of(context);
  AppStore get _store => _app.store;
  HueHub get _hub => _app.hub;
  List<String> get _ids => _store.lightIdsFor(widget.targetId);

  late final _brightness = PacedValue<double>(
    send: (v, {required confirmed}) =>
        _hub.setBrightness(_ids, v.round(), fast: !confirmed),
    onError: _error,
  );
  late final _kelvin = PacedValue<double>(
    send: (k, {required confirmed}) =>
        _hub.setTemperature(_ids, kelvinToMireds(k), fast: !confirmed),
    onError: _error,
  );
  late final _color = PacedValue<HueSat>(
    send: (hs, {required confirmed}) {
      final c = HSVColor.fromAHSV(1, hs.hue, hs.sat, 1).toColor();
      final xy = rgbToXy(c.r, c.g, c.b);
      return _hub.setColor(_ids, xy.x, xy.y, fast: !confirmed);
    },
    onError: _error,
  );

  /// Shown while a power write is in flight, so the switch flips at once.
  bool? _powerOverride;
  double _effectSpeed = 128;

  /// Hue to keep when the bulb reports a near-white colour (hue undefined).
  double _lastHue = 30;

  @override
  void dispose() {
    _brightness.dispose();
    _kelvin.dispose();
    _color.dispose();
    super.dispose();
  }

  void _error(Object e) {
    if (mounted) showError(context, e);
  }

  Future<void> _setPower(bool on) async {
    HapticFeedback.selectionClick();
    setState(() => _powerOverride = on);
    try {
      await _hub.setPower(_ids, on);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _powerOverride = null);
    }
  }

  /// Adjusting a light that's off switches it on, like the Hue app.
  void _ensureOn() {
    if (!(_powerOverride ?? _hub.anyOn(_ids))) _setPower(true);
  }

  HueSat _hueSatOf(XyColor? xy) {
    if (xy == null) return (hue: _lastHue, sat: 0);
    final hsv = HSVColor.fromColor(xyColor(xy));
    return (
      hue: hsv.saturation < 0.05 ? _lastHue : hsv.hue,
      sat: hsv.saturation,
    );
  }

  void _pickSwatch(Color c) {
    HapticFeedback.selectionClick();
    final hsv = HSVColor.fromColor(c);
    _lastHue = hsv.hue;
    _ensureOn();
    _color.set((hue: hsv.hue, sat: hsv.saturation));
  }

  Future<void> _setEffect(HueEffect e) async {
    HapticFeedback.selectionClick();
    try {
      await _hub.setEffect(_ids, e, speed: _effectSpeed.round());
    } catch (err) {
      _error(err);
    }
  }

  static IconData _effectIcon(HueEffect e) => switch (e) {
    HueEffect.candle => Icons.local_fire_department_outlined,
    HueEffect.fireplace => Icons.fireplace_outlined,
    HueEffect.prism => Icons.gradient,
    HueEffect.sunrise => Icons.wb_twilight,
    HueEffect.sunset => Icons.nights_stay_outlined,
    HueEffect.sparkle => Icons.auto_awesome,
    HueEffect.opal => Icons.blur_on,
    HueEffect.glisten => Icons.flare,
    HueEffect.underwater => Icons.water,
    HueEffect.cosmos => Icons.nightlight_round,
    HueEffect.sunbeam => Icons.wb_sunny_outlined,
    HueEffect.enchant => Icons.auto_fix_high,
    HueEffect.none => Icons.block,
  };

  Future<void> _applyPreset(Preset p) async {
    HapticFeedback.lightImpact();
    final ids = _ids.toSet();
    try {
      await _hub.applyLooks({
        for (final e in p.looks.entries)
          if (ids.contains(e.key)) e.key: e.value,
      });
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _savePreset() async {
    final looks = _hub.snapshot(_ids);
    if (looks.isEmpty) return;
    final name = await askName(
      context,
      title: 'Save preset',
      initial: 'Preset ${_store.presetsFor(widget.targetId).length + 1}',
    );
    if (name == null) return;
    await _store.savePreset(
      Preset(
        id: newId('p'),
        name: name,
        scopeId: widget.targetId,
        looks: looks,
      ),
    );
  }

  Future<void> _presetOptions(Preset p) async {
    HapticFeedback.mediumImpact();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                p.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('Update to the current look'),
              onTap: () => Navigator.pop(context, 'update'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        final name = await askName(
          context,
          title: 'Rename preset',
          initial: p.name,
        );
        if (name != null) await _store.savePreset(p.copyWith(name: name));
      case 'update':
        final looks = _hub.snapshot(_ids);
        if (looks.isNotEmpty) {
          await _store.savePreset(
            Preset(id: p.id, name: p.name, scopeId: p.scopeId, looks: looks),
          );
        }
      case 'delete':
        await _store.removePreset(p.id);
    }
  }

  Future<void> _sleepTimer() async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Sleep timer'),
              subtitle: Text(
                'Dims slowly, then turns off. Keep the app open until it '
                'finishes.',
              ),
            ),
            for (final m in const [5, 15, 30, 60])
              ListTile(
                leading: const Icon(Icons.bedtime_outlined),
                title: Text('$m minutes'),
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      ),
    );
    if (minutes == null) return;
    await _hub.fadeOut(widget.targetId, Duration(minutes: minutes));
  }

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final isGroup = store.group(widget.targetId) != null;
        final ids = _ids;
        final exists = isGroup || store.light(widget.targetId) != null;
        final lights = hub.connected(ids);
        return Scaffold(
          appBar: AppBar(
            title: Text(store.nameOf(widget.targetId)),
            actions: [
              if (lights.isNotEmpty)
                IconButton(
                  tooltip: 'Sleep timer',
                  icon: const Icon(Icons.bedtime_outlined),
                  onPressed: _sleepTimer,
                ),
              if (exists)
                IconButton(
                  tooltip: 'Details',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => isGroup
                      ? showGroupInfo(context, widget.targetId)
                      : showLightInfo(context, widget.targetId),
                ),
            ],
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: !exists
                ? const _Waiting(
                    key: ValueKey('gone'),
                    icon: Icons.lightbulb_outline,
                    text: 'This was removed.',
                  )
                : lights.isEmpty
                ? _waiting(isGroup, ids)
                : _controls(context, isGroup, ids, lights),
          ),
        );
      },
    );
  }

  Widget _waiting(bool isGroup, List<String> ids) {
    if (isGroup) {
      return _Waiting(
        key: const ValueKey('waiting'),
        icon: Icons.bluetooth_searching,
        text: ids.isEmpty
            ? 'This group has no lights.'
            : 'Waiting for the lights in this group…',
        busy: ids.isNotEmpty,
      );
    }
    final status = _hub.statusOf(widget.targetId);
    final busy = status == LinkStatus.connecting;
    return _Waiting(
      key: const ValueKey('waiting'),
      icon: busy ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
      text: statusText(status, _hub.errorOf(widget.targetId)),
      busy: busy,
      action: busy
          ? null
          : FilledButton(
              onPressed: () => _hub.retry(widget.targetId),
              child: const Text('Try again'),
            ),
    );
  }

  Widget _controls(
    BuildContext context,
    bool isGroup,
    List<String> ids,
    List<HueLight> lights,
  ) {
    final theme = Theme.of(context);
    final primary = lights.first.state;
    final on = _powerOverride ?? lights.any((l) => l.state.on);
    final white = lights.where((l) => l.supportsTemperature).firstOrNull;
    final colored = lights.where((l) => l.supportsColor).firstOrNull;
    final effects = lights.where((l) => l.supportsEffects).firstOrNull;
    final natural = ids.isNotEmpty && ids.every(_store.isNatural);
    final glow = stateColor(primary);
    final fadeEnds = _hub.fadeEndsAt(widget.targetId);
    final presets = _store.presetsFor(widget.targetId);

    return ListView(
      key: const ValueKey('controls'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _PowerTile(
          on: on,
          color: dimmed(glow, primary.brightness),
          subtitle: isGroup
              ? '${lights.length} of ${ids.length} lights connected'
              : null,
          onChanged: _setPower,
        ),
        if (fadeEnds != null)
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(
                'Fading off · done at ${TimeOfDay.fromDateTime(fadeEnds).format(context)}',
              ),
              trailing: TextButton(
                onPressed: () => _hub.cancelFade(widget.targetId),
                child: const Text('Cancel'),
              ),
            ),
          ),
        ListenableBuilder(
          listenable: _brightness,
          builder: (context, _) {
            final b = _brightness.shown ?? primary.brightness.toDouble();
            return ControlCard(
              title: 'Brightness',
              trailing: Text('${(b / maxBrightness * 100).round()}%'),
              child: FatSlider(
                semanticLabel: 'Brightness',
                value: b,
                min: minBrightness.toDouble(),
                max: maxBrightness.toDouble(),
                gradient: LinearGradient(
                  colors: [dimmed(glow, 1).withValues(alpha: 0.9), glow],
                ),
                dragging: _brightness.dragging,
                onChangeStart: (v) {
                  HapticFeedback.selectionClick();
                  _ensureOn();
                  _brightness.start(v);
                },
                onChanged: _brightness.update,
                onChangeEnd: _brightness.end,
              ),
            );
          },
        ),
        if (white != null)
          ListenableBuilder(
            listenable: _kelvin,
            builder: (context, _) {
              final k =
                  _kelvin.shown ??
                  miredsToKelvin(white.state.mireds ?? 370)
                      .toDouble()
                      .clamp(_minKelvin, _maxKelvin);
              return ControlCard(
                title: 'White',
                trailing: Text('${k.round()} K'),
                child: Column(
                  children: [
                    FatSlider(
                      semanticLabel: 'White colour temperature',
                      value: k,
                      min: _minKelvin,
                      max: _maxKelvin,
                      gradient: warmToCool,
                      ticks: [for (final (_, v) in _whiteNotches) v],
                      dragging: _kelvin.dragging,
                      onChangeStart: (v) {
                        HapticFeedback.selectionClick();
                        _ensureOn();
                        _kelvin.start(v);
                      },
                      onChanged: _kelvin.update,
                      onChangeEnd: _kelvin.end,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final (label, v) in _whiteNotches)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: _NotchButton(
                                label: label,
                                detail: '${v.round()} K',
                                color: kelvinColor(v),
                                selected: (k - v).abs() < 60,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  _ensureOn();
                                  _kelvin.set(v);
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.wb_twilight),
                      title: const Text('Natural light'),
                      subtitle: Text(
                        'White follows the time of day'
                        '${natural ? ' · now ${naturalKelvin(DateTime.now()).round()} K' : ''}. '
                        'Changing the white turns it off.',
                      ),
                      value: natural,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        _hub.setNatural(ids, v);
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        if (colored != null)
          ListenableBuilder(
            listenable: _color,
            builder: (context, _) {
              final hs = _color.shown ?? _hueSatOf(colored.state.xy);
              final preview = HSVColor.fromAHSV(1, hs.hue, hs.sat, 1).toColor();
              return ControlCard(
                title: 'Colour',
                trailing: LightDot(color: preview, on: true, size: 24),
                child: Column(
                  children: [
                    FatSlider(
                      semanticLabel: 'Hue',
                      value: hs.hue,
                      min: 0,
                      max: 360,
                      gradient: rainbow,
                      dragging: _color.dragging,
                      onChangeStart: (v) {
                        HapticFeedback.selectionClick();
                        _ensureOn();
                        _color.start((hue: v, sat: hs.sat));
                      },
                      onChanged: (v) {
                        _lastHue = v;
                        _color.update((hue: v, sat: hs.sat));
                      },
                      onChangeEnd: (v) => _color.end((hue: v, sat: hs.sat)),
                    ),
                    const SizedBox(height: 12),
                    FatSlider(
                      semanticLabel: 'Saturation',
                      value: hs.sat,
                      min: 0,
                      max: 1,
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, hs.hue, 1, 1).toColor(),
                        ],
                      ),
                      dragging: _color.dragging,
                      onChangeStart: (v) {
                        HapticFeedback.selectionClick();
                        _ensureOn();
                        _color.start((hue: hs.hue, sat: v));
                      },
                      onChanged: (v) => _color.update((hue: hs.hue, sat: v)),
                      onChangeEnd: (v) => _color.end((hue: hs.hue, sat: v)),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final c in _swatches)
                          _Swatch(color: c, onTap: () => _pickSwatch(c)),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        if (effects != null)
          ControlCard(
            title: 'Effects',
            trailing: effects.state.effect == HueEffect.none
                ? null
                : TextButton(
                    onPressed: () => _setEffect(HueEffect.none),
                    child: const Text('Stop'),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in HueEffect.values.skip(1))
                      ChoiceChip(
                        label: Text(e.label),
                        avatar: Icon(_effectIcon(e), size: 18),
                        selected: effects.state.effect == e,
                        onSelected: (sel) =>
                            _setEffect(sel ? e : HueEffect.none),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('Speed', style: theme.textTheme.bodyMedium),
                    Expanded(
                      child: Slider(
                        value: _effectSpeed,
                        max: 255,
                        onChanged: (v) => setState(() => _effectSpeed = v),
                        onChangeEnd: (_) {
                          final e = effects.state.effect;
                          if (e != HueEffect.none) _setEffect(e);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ControlCard(
          title: 'Scenes',
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ScenesPage(targetId: widget.targetId),
              ),
            ),
            child: Text('Browse all ${hueScenes.length}'),
          ),
          child: SizedBox(
            height: 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final scene in hueScenes.where((s) => s.set == 'Defaults'))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 104,
                      child: SceneTile(
                        scene: scene,
                        onTap: () =>
                            applyScene(context, widget.targetId, scene),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        ControlCard(
          title: 'Presets',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in presets)
                GestureDetector(
                  onLongPress: () => _presetOptions(p),
                  child: ActionChip(
                    avatar: LightDot(color: presetColor(p), on: true, size: 18),
                    label: Text(p.name),
                    onPressed: () => _applyPreset(p),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Save current look'),
                onPressed: _savePreset,
              ),
            ],
          ),
        ),
        if (presets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Text(
              'Tap a preset to apply it. Long-press to rename, update or '
              'delete.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _PowerTile extends StatelessWidget {
  const _PowerTile({
    required this.on,
    required this.color,
    required this.onChanged,
    this.subtitle,
  });

  final bool on;
  final Color color;
  final String? subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = on
        ? (ThemeData.estimateBrightnessForColor(color) == Brightness.dark
              ? Colors.white
              : Colors.black87)
        : scheme.onSurface;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onChanged(!on),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 20),
          decoration: BoxDecoration(
            gradient: on
                ? RadialGradient(
                    center: const Alignment(-0.8, -0.6),
                    radius: 1.6,
                    colors: [color, Color.lerp(color, scheme.surface, 0.55)!],
                  )
                : null,
            color: on ? null : scheme.surfaceContainerHighest,
          ),
          child: Row(
            children: [
              Icon(
                on ? Icons.lightbulb : Icons.lightbulb_outline,
                size: 36,
                color: fg,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      on ? 'On' : 'Off',
                      style: theme.textTheme.titleLarge?.copyWith(color: fg),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(color: fg),
                      ),
                  ],
                ),
              ),
              Switch(value: on, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotchButton extends StatelessWidget {
  const _NotchButton({
    required this.label,
    required this.detail,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? scheme.secondary : scheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LightDot(color: color, on: true, size: 10),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
              Text(
                detail,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: CircleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const SizedBox(width: 34, height: 34),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({
    super.key,
    required this.icon,
    required this.text,
    this.busy = false,
    this.action,
  });

  final IconData icon;
  final String text;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const CircularProgressIndicator()
            else
              Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
