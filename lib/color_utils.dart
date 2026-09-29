// Colour conversions for Hue lights, following Philips' documented
// RGB <-> CIE 1931 xy conversion (Wide RGB D65 gamut). Pure Dart, no Flutter.

import 'dart:math' as math;

/// D65 white point, returned when a colour has no chromaticity (black).
const double whiteX = 0.3127;
const double whiteY = 0.3290;

/// Mired limits accepted by Hue bulbs (6500 K .. 2000 K).
const int minMireds = 153;
const int maxMireds = 500;

/// A CIE 1931 chromaticity coordinate.
class XyColor {
  final double x;
  final double y;

  const XyColor(this.x, this.y);

  @override
  bool operator ==(Object other) =>
      other is XyColor && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'XyColor($x, $y)';
}

/// An sRGB colour with channels in 0..1.
class RgbColor {
  final double r;
  final double g;
  final double b;

  const RgbColor(this.r, this.g, this.b);

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'RgbColor($r, $g, $b)';
}

double _linearize(double c) =>
    c > 0.04045 ? math.pow((c + 0.055) / 1.055, 2.4).toDouble() : c / 12.92;

double _gamma(double c) => c <= 0.0031308
    ? 12.92 * c
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

/// Converts sRGB (each channel 0..1) to CIE xy.
XyColor rgbToXy(double red, double green, double blue) {
  final r = _linearize(red.clamp(0.0, 1.0));
  final g = _linearize(green.clamp(0.0, 1.0));
  final b = _linearize(blue.clamp(0.0, 1.0));

  final x = r * 0.664511 + g * 0.154324 + b * 0.162028;
  final y = r * 0.283881 + g * 0.668433 + b * 0.047685;
  final z = r * 0.000088 + g * 0.072310 + b * 0.986039;

  final sum = x + y + z;
  if (sum == 0) return const XyColor(whiteX, whiteY);
  return XyColor(x / sum, y / sum);
}

/// Converts CIE xy to sRGB (each channel 0..1) at full brightness.
RgbColor xyToRgb(double x, double y) {
  if (y <= 0) return const RgbColor(1, 1, 1);

  final z = 1 - x - y;
  const bigY = 1.0;
  final bigX = (bigY / y) * x;
  final bigZ = (bigY / y) * z;

  var r = bigX * 1.656492 - bigY * 0.354851 - bigZ * 0.255038;
  var g = -bigX * 0.707196 + bigY * 1.655397 + bigZ * 0.036152;
  var b = bigX * 0.051713 - bigY * 0.121364 + bigZ * 1.011530;

  r = math.max(0.0, r);
  g = math.max(0.0, g);
  b = math.max(0.0, b);

  final maxChannel = math.max(r, math.max(g, b));
  if (maxChannel > 1) {
    r /= maxChannel;
    g /= maxChannel;
    b /= maxChannel;
  }

  return RgbColor(
    _gamma(r).clamp(0.0, 1.0),
    _gamma(g).clamp(0.0, 1.0),
    _gamma(b).clamp(0.0, 1.0),
  );
}

/// Kelvin to mireds, clamped to what Hue bulbs accept.
int kelvinToMireds(num kelvin) {
  if (kelvin <= 0) return maxMireds;
  return (1e6 / kelvin).round().clamp(minMireds, maxMireds);
}

/// Mireds to kelvin.
int miredsToKelvin(int mireds) {
  if (mireds <= 0) return 6500;
  return (1e6 / mireds).round();
}
