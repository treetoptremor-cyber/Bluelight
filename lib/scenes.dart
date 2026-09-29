import 'dart:math' as math;

import 'color_utils.dart';
import 'hue_ble.dart';
import 'models.dart';

/// One colour of a scene's palette: either an xy colour or a white
/// temperature in mireds.
class SceneColor {
  const SceneColor.xy(double this.x, double this.y) : ct = null;
  const SceneColor.ct(int this.ct) : x = null, y = null;

  final double? x;
  final double? y;
  final int? ct;

  bool get isWhite => ct != null;
  XyColor? get xy => x == null ? null : XyColor(x!, y!);
}

/// A scene: a palette spread over the lights, at one brightness.
class HueScene {
  const HueScene(this.name, this.set, this.brightness, this.colors);

  final String name;

  /// Gallery group, e.g. "Cozy". "Defaults" are the white recipes.
  final String set;
  final int brightness;
  final List<SceneColor> colors;

  bool get isWhite => colors.every((c) => c.isWhite);
}

/// What a light can show, for picking the closest look.
class LightAbilities {
  const LightAbilities({required this.color, required this.white});

  final bool color;
  final bool white;
}

/// Approximate colour temperature of an xy colour (McCamy's formula), as
/// mireds clamped to what Hue bulbs accept.
int xyToMireds(XyColor xy) {
  final n = (xy.x - 0.3320) / (0.1858 - xy.y);
  final kelvin =
      449 * math.pow(n, 3) + 3525 * math.pow(n, 2) + 6823.3 * n + 5520.33;
  return kelvinToMireds(kelvin.clamp(1000, 20000));
}

/// The look each light gets from [scene]: lights take the palette's colours
/// in turn. Lights without colour get the nearest white; plain white bulbs
/// just get the brightness.
Map<String, LightLook> sceneLooks(
  HueScene scene,
  Map<String, LightAbilities> lights,
) {
  final out = <String, LightLook>{};
  var i = 0;
  for (final e in lights.entries) {
    final c = scene.colors[i++ % scene.colors.length];
    final can = e.value;
    if (c.isWhite || !can.color) {
      final mireds = c.ct ?? xyToMireds(c.xy!);
      out[e.key] = LightLook(
        on: true,
        brightness: scene.brightness.clamp(minBrightness, maxBrightness),
        mode: HueMode.white,
        mireds: can.white ? mireds : null,
      );
    } else {
      out[e.key] = LightLook(
        on: true,
        brightness: scene.brightness.clamp(minBrightness, maxBrightness),
        mode: HueMode.color,
        xy: c.xy,
      );
    }
  }
  return out;
}
