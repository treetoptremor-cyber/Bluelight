import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'color_utils.dart';
import 'hue_ble.dart';

const _minKelvin = 2000.0;
const _maxKelvin = 6500.0;

const _swatches = <Color>[
  Color(0xFFFF0000),
  Color(0xFFFF8000),
  Color(0xFFFFE000),
  Color(0xFF00FF00),
  Color(0xFF00E0FF),
  Color(0xFF0000FF),
  Color(0xFFB000FF),
  Color(0xFFFF40A0),
];

enum _Phase { connecting, ready, failed, disconnected }

/// Connects to one bulb and shows its controls.
class LightPage extends StatefulWidget {
  const LightPage({super.key, required this.device});

  final BluetoothDevice device;

  @override
  State<LightPage> createState() => _LightPageState();
}

class _LightPageState extends State<LightPage> {
  late final HueLight _light = HueLight(widget.device);
  late final StreamSubscription<HueLightState> _stateSub;
  late final StreamSubscription<BluetoothConnectionState> _connectionSub;

  late final _brightness = _SliderControl(_showWriteError);
  late final _temperature = _SliderControl(_showWriteError);
  late final _color = _SliderControl(_showWriteError);

  _Phase _phase = _Phase.connecting;
  String _status = 'Connecting…';
  String? _error;
  HueLightState _state = const HueLightState();

  double _hue = 0;
  double _saturation = 1;

  /// The xy we last wrote, as the bulb stores it. Used to avoid moving the
  /// colour sliders when the bulb echoes our own write back.
  XyColor? _lastWrittenXy;

  @override
  void initState() {
    super.initState();
    _stateSub = _light.stateStream.listen(_onState);
    _connectionSub = widget.device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected &&
          _phase == _Phase.ready &&
          mounted) {
        setState(() => _phase = _Phase.disconnected);
      }
    });
    _connect();
  }

  @override
  void dispose() {
    for (final c in [_brightness, _temperature, _color]) {
      c.writer.close();
    }
    _stateSub.cancel();
    _connectionSub.cancel();
    _light.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _phase = _Phase.connecting;
      _status = 'Connecting…';
      _error = null;
    });
    try {
      await _light.connect(
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.ready);
      _onState(_light.state);
    } catch (e) {
      try {
        await widget.device.disconnect();
      } catch (_) {
        // Nothing to clean up.
      }
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = _describeError(e);
      });
    }
  }

  void _onState(HueLightState s) {
    if (!mounted) return;
    setState(() {
      _state = s;
      final xy = s.xy;
      // Leave the colour sliders alone while they are in use, and ignore the
      // bulb echoing back what we just wrote.
      if (xy != null &&
          !_color.dragging &&
          _color.value == null &&
          xy != _lastWrittenXy) {
        final rgb = xyToRgb(xy.x, xy.y);
        final hsv = HSVColor.fromColor(
          Color.from(alpha: 1, red: rgb.r, green: rgb.g, blue: rgb.b),
        );
        _hue = hsv.hue;
        _saturation = hsv.saturation;
      }
    });
  }

  String _describeError(Object e) {
    if (e is StateError) return e.message;
    if (e is TimeoutException) {
      return 'Timed out. Is the bulb powered on and in range?';
    }
    final text = e is FlutterBluePlusException
        ? (e.description ?? 'Bluetooth error ${e.code}')
        : e.toString();
    final lower = text.toLowerCase();
    if (lower.contains('authentication') || lower.contains('encryption')) {
      return '$text\n\nThe phone is not paired with this bulb. If it was set '
          'up in the Hue Bluetooth app, reset it there, forget it in the '
          "phone's Bluetooth settings, then try again.";
    }
    return text;
  }

  void _showWriteError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_describeError(e))));
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _showWriteError(e);
    }
  }

  // Slider plumbing: writes are throttled while dragging, the final value is
  // always written on release, and bulb notifications don't move a slider
  // that is being dragged (or whose final write is still in flight).

  void _dragStart(_SliderControl c, double v) => setState(() {
    c.dragging = true;
    c.value = v;
  });

  void _dragUpdate(_SliderControl c, double v, Future<void> Function() write) {
    setState(() => c.value = v);
    c.writer.add(write);
  }

  void _dragEnd(_SliderControl c, double v, Future<void> Function() write) {
    c.dragging = false;
    setState(() => c.value = v);
    c.writer.add(write).then((_) {
      if (mounted && !c.dragging) setState(() => c.value = null);
    });
  }

  Future<void> Function() _brightnessWrite(double v) =>
      () => _light.setBrightness(v.round());

  Future<void> Function() _temperatureWrite(double kelvin) =>
      () => _light.setTemperature(kelvinToMireds(kelvin));

  Future<void> Function() _colorWrite() {
    final c = HSVColor.fromAHSV(1, _hue, _saturation, 1).toColor();
    final xy = rgbToXy(c.r, c.g, c.b);
    _lastWrittenXy = decodeXy(encodeXy(xy.x, xy.y));
    return () => _light.setColor(xy.x, xy.y);
  }

  void _pickSwatch(Color color) {
    final hsv = HSVColor.fromColor(color);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    // Same path as releasing a slider, so echoes of earlier taps can't move
    // the sliders while this write is still queued.
    _dragEnd(_color, _hue, _colorWrite());
  }

  @override
  Widget build(BuildContext context) {
    final ready = _phase == _Phase.ready;
    return Scaffold(
      appBar: AppBar(
        title: Text(ready ? _light.name : _fallbackName()),
        actions: [
          if (ready)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => _run(_light.refresh),
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.connecting => _Centered(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(_status, textAlign: TextAlign.center),
          ],
        ),
        _Phase.failed => _Centered(
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(_error ?? 'Could not connect.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: _connect, child: const Text('Retry')),
          ],
        ),
        _Phase.disconnected => _Centered(
          children: [
            Icon(
              Icons.bluetooth_disabled,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text('Disconnected'),
            const SizedBox(height: 24),
            FilledButton(onPressed: _connect, child: const Text('Reconnect')),
          ],
        ),
        _Phase.ready => _controls(context),
      },
    );
  }

  String _fallbackName() {
    for (final n in [widget.device.platformName, widget.device.advName]) {
      if (n.trim().isNotEmpty) return n.trim();
    }
    return 'Hue light';
  }

  Widget _controls(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = _brightness.value ?? _state.brightness.toDouble();
    final kelvin =
        _temperature.value ??
        miredsToKelvin(_state.mireds ?? 370)
            .toDouble()
            .clamp(_minKelvin, _maxKelvin);
    final previewColor = HSVColor.fromAHSV(1, _hue, _saturation, 1).toColor();
    final info = [
      if (_light.modelNumber case final m?) 'Model $m',
      widget.device.remoteId.str,
    ].join(' · ');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: SwitchListTile(
            secondary: Icon(
              _state.on ? Icons.lightbulb : Icons.lightbulb_outline,
            ),
            title: const Text('Power'),
            value: _state.on,
            onChanged: (on) => _run(() => _light.setPower(on)),
          ),
        ),
        _ControlCard(
          title: 'Brightness',
          trailing: '${(brightness / maxBrightness * 100).round()}%',
          child: Slider(
            min: minBrightness.toDouble(),
            max: maxBrightness.toDouble(),
            value: brightness.clamp(
              minBrightness.toDouble(),
              maxBrightness.toDouble(),
            ),
            onChangeStart: (v) => _dragStart(_brightness, v),
            onChanged: (v) => _dragUpdate(_brightness, v, _brightnessWrite(v)),
            onChangeEnd: (v) => _dragEnd(_brightness, v, _brightnessWrite(v)),
          ),
        ),
        if (_light.supportsTemperature)
          _ControlCard(
            title: 'White',
            trailing: '${kelvin.round()} K',
            child: Column(
              children: [
                _GradientSlider(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFFF9329),
                      Color(0xFFFFF1E0),
                      Color(0xFFD6E4FF),
                    ],
                  ),
                  min: _minKelvin,
                  max: _maxKelvin,
                  value: kelvin,
                  onChangeStart: (v) => _dragStart(_temperature, v),
                  onChanged: (v) =>
                      _dragUpdate(_temperature, v, _temperatureWrite(v)),
                  onChangeEnd: (v) =>
                      _dragEnd(_temperature, v, _temperatureWrite(v)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Warm', style: theme.textTheme.bodySmall),
                      Text('Cool', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_light.supportsColor)
          _ControlCard(
            title: 'Colour',
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: previewColor,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Column(
              children: [
                _GradientSlider(
                  gradient: LinearGradient(
                    colors: [
                      for (var h = 0; h <= 360; h += 60)
                        HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
                    ],
                  ),
                  min: 0,
                  max: 360,
                  value: _hue,
                  onChangeStart: (v) => _dragStart(_color, v),
                  onChanged: (v) {
                    _hue = v;
                    _dragUpdate(_color, v, _colorWrite());
                  },
                  onChangeEnd: (v) {
                    _hue = v;
                    _dragEnd(_color, v, _colorWrite());
                  },
                ),
                _GradientSlider(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white,
                      HSVColor.fromAHSV(1, _hue, 1, 1).toColor(),
                    ],
                  ),
                  min: 0,
                  max: 1,
                  value: _saturation,
                  onChangeStart: (v) => _dragStart(_color, v),
                  onChanged: (v) {
                    _saturation = v;
                    _dragUpdate(_color, v, _colorWrite());
                  },
                  onChangeEnd: (v) {
                    _saturation = v;
                    _dragEnd(_color, v, _colorWrite());
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final c in _swatches)
                      _Swatch(color: c, onTap: () => _pickSwatch(c)),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          info,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Per-slider state: whether the user is dragging, the value to show instead
/// of the bulb's (while dragging and until the final write lands), and the
/// throttled writer.
class _SliderControl {
  _SliderControl(void Function(Object error) onError)
    : writer = _WriteThrottle(onError);

  final _WriteThrottle writer;
  bool dragging = false;
  double? value;
}

/// Runs at most one write per [interval] and never two at once. Only the
/// latest pending write is kept, so a fast drag doesn't build a queue.
class _WriteThrottle {
  _WriteThrottle(this.onError);

  static const interval = Duration(milliseconds: 120);

  final void Function(Object error) onError;
  Future<void> Function()? _pending;
  Completer<void>? _idle;
  bool _closed = false;

  /// Queues [write]. The future completes once nothing is left to write.
  Future<void> add(Future<void> Function() write) {
    if (_closed) return Future.value();
    _pending = write;
    final idle = _idle;
    if (idle != null) return idle.future;
    final started = _idle = Completer<void>();
    _pump();
    return started.future;
  }

  Future<void> _pump() async {
    while (_pending != null && !_closed) {
      final write = _pending!;
      _pending = null;
      final watch = Stopwatch()..start();
      try {
        await write();
      } catch (e) {
        if (!_closed) onError(e);
      }
      final rest = interval - watch.elapsed;
      if (rest > Duration.zero) await Future<void>.delayed(rest);
    }
    final idle = _idle;
    _idle = null;
    idle?.complete();
  }

  void close() {
    _closed = true;
    _pending = null;
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.title,
    required this.child,
    this.trailing,
    this.leading,
  });

  final String title;
  final String? trailing;
  final Widget? leading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null)
                  Text(trailing!, style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// A slider whose track is painted with [gradient].
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.gradient,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  final Gradient gradient;
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context)
          .copyWith(trackHeight: 12, trackShape: _GradientTrackShape(gradient)),
      child: Slider(
        min: min,
        max: max,
        value: value.clamp(min, max),
        onChangeStart: onChangeStart,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

class _GradientTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _GradientTrackShape(this.gradient);

  final Gradient gradient;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..shader = gradient.createShader(rect),
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
        child: const SizedBox(width: 36, height: 36),
      ),
    );
  }
}
