import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bulb_scheduler.dart';
import '../color_utils.dart';
import '../diagnostics.dart';
import '../hub.dart';
import '../hue_ble.dart';
import '../models.dart';
import '../routine_runner.dart';
import '../store.dart';

/// Gives every page the store, hub and routine runner.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.store,
    required this.hub,
    required this.runner,
    this.scheduler,
    required super.child,
  });

  final AppStore store;
  final HueHub hub;
  final RoutineRunner runner;

  /// Null in tests.
  final BulbScheduler? scheduler;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      store != old.store || hub != old.hub || runner != old.runner;
}

/// Rebuilds when the store or hub changes.
class AppBuilder extends StatelessWidget {
  const AppBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, AppStore store, HueHub hub)
  builder;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.store, app.hub]),
      builder: (context, _) => builder(context, app.store, app.hub),
    );
  }
}

// --- Colours

const _kelvinStops = <(double, Color)>[
  (2000, Color(0xFFFF8A2B)),
  (2700, Color(0xFFFFB46B)),
  (4000, Color(0xFFFFE7C8)),
  (5000, Color(0xFFFFF4EA)),
  (6500, Color(0xFFDCE7FF)),
];

/// Approximate colour of white light at [kelvin].
Color kelvinColor(double kelvin) {
  if (kelvin <= _kelvinStops.first.$1) return _kelvinStops.first.$2;
  for (var i = 1; i < _kelvinStops.length; i++) {
    final (k1, c1) = _kelvinStops[i];
    if (kelvin <= k1) {
      final (k0, c0) = _kelvinStops[i - 1];
      return Color.lerp(c0, c1, (kelvin - k0) / (k1 - k0))!;
    }
  }
  return _kelvinStops.last.$2;
}

final warmToCool = LinearGradient(
  colors: [for (final (_, c) in _kelvinStops) c],
);

final rainbow = LinearGradient(
  colors: [
    for (var h = 0; h <= 360; h += 30)
      HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
  ],
);

Color xyColor(XyColor xy) {
  final rgb = xyToRgb(xy.x, xy.y);
  return Color.from(alpha: 1, red: rgb.r, green: rgb.g, blue: rgb.b);
}

/// The colour a light is showing, at full brightness.
Color lookColor({required HueMode? mode, int? mireds, XyColor? xy}) {
  if (mode == HueMode.color && xy != null) return xyColor(xy);
  if (mireds != null) return kelvinColor(miredsToKelvin(mireds).toDouble());
  if (xy != null) return xyColor(xy);
  return kelvinColor(2700);
}

Color stateColor(HueLightState s) =>
    lookColor(mode: s.mode, mireds: s.mireds, xy: s.xy);

Color presetColor(Preset p) {
  final look = p.looks.values.where((l) => l.on).firstOrNull;
  if (look == null) return Colors.black;
  return lookColor(mode: look.mode, mireds: look.mireds, xy: look.xy);
}

/// [c] dimmed to [brightness] (1..254), never fully black.
Color dimmed(Color c, int brightness) {
  final hsv = HSVColor.fromColor(c);
  return hsv
      .withValue(hsv.value * (0.25 + 0.75 * brightness / maxBrightness))
      .toColor();
}

// --- Status

String statusText(LinkStatus s, String? error) => switch (s) {
  LinkStatus.connected => 'Connected',
  LinkStatus.connecting => 'Connecting…',
  LinkStatus.unreachable =>
    "Can't reach it yet. Is it powered on and nearby? Still trying.",
  LinkStatus.failed => error ?? 'Connection failed. Retrying.',
  LinkStatus.offline => 'Not connected',
};

Color statusColor(LinkStatus s, ColorScheme scheme) => switch (s) {
  LinkStatus.connected => Colors.green,
  LinkStatus.connecting => scheme.outline,
  LinkStatus.unreachable => Colors.orange,
  LinkStatus.failed => scheme.error,
  LinkStatus.offline => scheme.outline,
};

// --- Widgets

/// A round swatch of the light's colour, or a hollow ring when it isn't
/// connected, or a dark dot when it is off.
class LightDot extends StatelessWidget {
  const LightDot({super.key, this.color, this.on = false, this.size = 28});

  /// Null when not connected.
  final Color? color;
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c == null
            ? Colors.transparent
            : on
            ? c
            : scheme.surfaceContainerHighest,
        border: Border.all(
          color: c == null ? scheme.outline : scheme.outlineVariant,
          width: c == null ? 1.5 : 1,
        ),
        boxShadow: [
          if (c != null && on)
            BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: size / 2),
        ],
      ),
    );
  }
}

/// A thick, rounded slider painted with [gradient], iOS style. When the
/// value changes from outside (not while dragging) the thumb glides there.
///
/// [ticks] are marked on the track; while dragging, the thumb snaps to a
/// tick when it comes within [snap] (a fraction of the range) with a light
/// haptic tap, and a release near one lands exactly on it.
class FatSlider extends StatefulWidget {
  const FatSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.gradient,
    required this.dragging,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    this.enabled = true,
    this.semanticLabel,
    this.ticks = const [],
    this.snap = 0.025,
  });

  final double value;
  final double min;
  final double max;
  final Gradient gradient;
  final bool dragging;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool enabled;
  final String? semanticLabel;
  final List<double> ticks;
  final double snap;

  @override
  State<FatSlider> createState() => _FatSliderState();
}

class _FatSliderState extends State<FatSlider> {
  static const _height = 44.0;
  double? _snappedTo;

  double _snapped(double v) {
    final range = widget.max - widget.min;
    for (final t in widget.ticks) {
      if ((v - t).abs() <= widget.snap * range) {
        if (_snappedTo != t) HapticFeedback.selectionClick();
        _snappedTo = t;
        return t;
      }
    }
    _snappedTo = null;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final outline = Theme.of(context).colorScheme.outlineVariant;
    final range = w.max - w.min;
    final tickFractions = [
      for (final t in w.ticks)
        if (range > 0) ((t - w.min) / range).clamp(0.0, 1.0),
    ];
    return Semantics(
      label: w.semanticLabel,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: w.enabled ? 1 : 0.4,
        child: SizedBox(
          height: _height + 8,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: w.value.clamp(w.min, w.max)),
            duration: w.dragging
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _height,
                trackShape: _FatTrack(w.gradient, outline, tickFractions),
                thumbShape: const _InsetThumb(_height / 2 - 5),
                overlayShape: SliderComponentShape.noOverlay,
                showValueIndicator: ShowValueIndicator.never,
                padding: EdgeInsets.zero,
              ),
              child: Slider(
                min: w.min,
                max: w.max,
                value: v.clamp(w.min, w.max),
                onChangeStart: w.enabled
                    ? (v) => w.onChangeStart(_snapped(v))
                    : null,
                onChanged: w.enabled ? (v) => w.onChanged(_snapped(v)) : null,
                onChangeEnd: w.enabled
                    ? (v) {
                        final end = _snapped(v);
                        _snappedTo = null;
                        w.onChangeEnd(end);
                      }
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FatTrack extends SliderTrackShape {
  const _FatTrack(this.gradient, this.outline, [this.ticks = const []]);

  final Gradient gradient;
  final Color outline;

  /// Tick positions as fractions of the thumb's travel.
  final List<double> ticks;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    // The thumb travels inside the track, half a track height from each end.
    final h = sliderTheme.trackHeight ?? 44;
    final top = offset.dy + (parentBox.size.height - h) / 2;
    return Rect.fromLTWH(offset.dx + h / 2, top, parentBox.size.width - h, h);
  }

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
    final inner = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );
    // Paint past the thumb's travel so the thumb sits inside the ends.
    final rect = Rect.fromLTRB(
      inner.left - inner.height / 2,
      inner.top,
      inner.right + inner.height / 2,
      inner.bottom,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.height / 2),
    );
    context.canvas
      ..drawRRect(rrect, Paint()..shader = gradient.createShader(rect))
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = outline,
      );
    // Small notches along the centre line of the track.
    final notch = Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final f in ticks) {
      final x = inner.left + f * inner.width;
      context.canvas
        ..drawLine(Offset(x, inner.top + 5), Offset(x, inner.top + 11), notch)
        ..drawLine(
          Offset(x, inner.bottom - 11),
          Offset(x, inner.bottom - 5),
          notch,
        );
    }
  }
}

class _InsetThumb extends SliderComponentShape {
  const _InsetThumb(this.radius);

  final double radius;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    // Grows slightly while held.
    final r = radius * (1 + 0.08 * activationAnimation.value);
    final canvas = context.canvas;
    canvas.drawCircle(
      center.translate(0, 1),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, r, Paint()..color = Colors.white);
  }
}

/// A card with a title row and content, used for each control.
class ControlCard extends StatelessWidget {
  const ControlCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// Asks for a name. Returns the trimmed text, or null if cancelled/empty.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String action = 'Save',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  );
  controller.dispose();
  final name = result?.trim();
  return name == null || name.isEmpty ? null : name;
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

void showError(BuildContext context, Object error) {
  diag('ui', 'error shown: $error');
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(describeBleError(error))));
}
