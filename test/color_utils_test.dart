import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/color_utils.dart';

void main() {
  group('rgbToXy', () {
    test('pure red is about (0.70, 0.30)', () {
      final xy = rgbToXy(1, 0, 0);
      expect(xy.x, closeTo(0.70, 0.01));
      expect(xy.y, closeTo(0.30, 0.01));
    });

    test('white is about (0.32, 0.33)', () {
      final xy = rgbToXy(1, 1, 1);
      expect(xy.x, closeTo(0.32, 0.01));
      expect(xy.y, closeTo(0.33, 0.01));
    });

    test('black falls back to D65 white', () {
      expect(rgbToXy(0, 0, 0), const XyColor(whiteX, whiteY));
    });
  });

  group('xyToRgb', () {
    test('red round trips', () {
      final xy = rgbToXy(1, 0, 0);
      final rgb = xyToRgb(xy.x, xy.y);
      expect(rgb.r, closeTo(1, 0.01));
      expect(rgb.g, lessThan(0.05));
      expect(rgb.b, lessThan(0.05));
    });

    test('green round trips', () {
      final xy = rgbToXy(0, 1, 0);
      final rgb = xyToRgb(xy.x, xy.y);
      expect(rgb.g, closeTo(1, 0.01));
      expect(rgb.r, lessThan(0.05));
      expect(rgb.b, lessThan(0.05));
    });

    test('blue round trips', () {
      final xy = rgbToXy(0, 0, 1);
      final rgb = xyToRgb(xy.x, xy.y);
      expect(rgb.b, closeTo(1, 0.01));
      expect(rgb.r, lessThan(0.05));
      expect(rgb.g, lessThan(0.05));
    });

    test('channels stay within 0..1', () {
      for (final xy in const [
        XyColor(0.0, 0.0),
        XyColor(0.1, 0.8),
        XyColor(0.7, 0.3),
        XyColor(0.15, 0.05),
        XyColor(1.0, 1.0),
      ]) {
        final rgb = xyToRgb(xy.x, xy.y);
        for (final c in [rgb.r, rgb.g, rgb.b]) {
          expect(c, inInclusiveRange(0, 1), reason: '$xy -> $rgb');
        }
      }
    });

    test('non-positive y returns white', () {
      expect(xyToRgb(0.3, 0), const RgbColor(1, 1, 1));
    });
  });

  group('temperature', () {
    test('kelvin to mireds', () {
      expect(kelvinToMireds(2700), 370);
      expect(kelvinToMireds(6500), 154);
      expect(kelvinToMireds(2000), 500);
    });

    test('kelvinToMireds clamps to 153..500', () {
      expect(kelvinToMireds(10000), minMireds);
      expect(kelvinToMireds(1000), maxMireds);
      expect(kelvinToMireds(0), maxMireds);
    });

    test('mireds to kelvin', () {
      expect(miredsToKelvin(370), 2703);
      expect(miredsToKelvin(153), 6536);
      expect(miredsToKelvin(500), 2000);
    });

    test('kelvin <-> mireds round trip', () {
      for (final k in [2000, 2700, 3000, 4000, 5000, 6500]) {
        final back = miredsToKelvin(kelvinToMireds(k));
        // One mired step is ~40 K at 6500 K, so allow that much drift.
        expect(back, closeTo(k, 45), reason: '$k K');
      }
      for (var m = minMireds; m <= maxMireds; m++) {
        expect(kelvinToMireds(miredsToKelvin(m)), m, reason: '$m mireds');
      }
    });
  });
}
