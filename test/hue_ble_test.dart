import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/color_utils.dart';
import 'package:hue_ble_remote/hue_ble.dart';

void main() {
  group('power', () {
    test('encodes on and off', () {
      expect(encodePower(true), [0x01]);
      expect(encodePower(false), [0x00]);
    });

    test('decodes on and off', () {
      expect(decodePower([0x01]), isTrue);
      expect(decodePower([0x00]), isFalse);
      expect(decodePower([]), isNull);
    });

    test('round trips', () {
      for (final on in [true, false]) {
        expect(decodePower(encodePower(on)), on);
      }
    });
  });

  group('brightness', () {
    test('encodes in range as one byte', () {
      expect(encodeBrightness(1), [1]);
      expect(encodeBrightness(128), [128]);
      expect(encodeBrightness(254), [254]);
    });

    test('clamps to 1..254', () {
      expect(encodeBrightness(0), [1]);
      expect(encodeBrightness(-5), [1]);
      expect(encodeBrightness(255), [254]);
      expect(encodeBrightness(1000), [254]);
      expect(decodeBrightness([0]), 1);
      expect(decodeBrightness([255]), 254);
    });

    test('round trips', () {
      for (var b = 1; b <= 254; b++) {
        expect(decodeBrightness(encodeBrightness(b)), b);
      }
      expect(decodeBrightness([]), isNull);
    });
  });

  group('temperature (mireds)', () {
    test('encodes little-endian', () {
      expect(encodeMireds(370), [0x72, 0x01]);
      expect(encodeMireds(153), [0x99, 0x00]);
      expect(encodeMireds(500), [0xF4, 0x01]);
    });

    test('clamps to 153..500', () {
      expect(encodeMireds(100), encodeMireds(153));
      expect(encodeMireds(0), encodeMireds(153));
      expect(encodeMireds(600), encodeMireds(500));
    });

    test('decodes little-endian', () {
      expect(decodeMireds([0x72, 0x01]), 370);
      expect(decodeMireds([0xC6, 0x01]), 454);
      expect(decodeMireds([0x72]), isNull);
    });

    test('round trips', () {
      for (var m = minMireds; m <= maxMireds; m++) {
        expect(decodeMireds(encodeMireds(m)), m);
      }
    });
  });

  group('colour (xy)', () {
    test('encodes [x_lo, x_hi, y_lo, y_hi]', () {
      expect(encodeXy(0, 0), [0, 0, 0, 0]);
      expect(encodeXy(1, 1), [0xFF, 0xFF, 0xFF, 0xFF]);
      // 0.5 * 0xFFFF = 32767.5 -> 32768 = 0x8000
      // 0.25 * 0xFFFF = 16383.75 -> 16384 = 0x4000
      expect(encodeXy(0.5, 0.25), [0x00, 0x80, 0x00, 0x40]);
    });

    test('clamps to 0..1', () {
      expect(encodeXy(-1, 2), [0, 0, 0xFF, 0xFF]);
    });

    test('decodes back within 1/65535', () {
      for (final xy in const [
        XyColor(0.3127, 0.3290),
        XyColor(0.7006, 0.2993),
        XyColor(0.1724, 0.7468),
        XyColor(0.1355, 0.0399),
        XyColor(0.0, 1.0),
      ]) {
        final back = decodeXy(encodeXy(xy.x, xy.y))!;
        expect(back.x, closeTo(xy.x, 1 / 65535), reason: '$xy');
        expect(back.y, closeTo(xy.y, 1 / 65535), reason: '$xy');
      }
    });

    test('short payload decodes to null', () {
      expect(decodeXy([1, 2, 3]), isNull);
    });
  });

  group('decodeString', () {
    test('strips trailing NULs and whitespace', () {
      expect(decodeString([0x48, 0x75, 0x65, 0x20, 0x00, 0x00]), 'Hue');
    });

    test('tolerates malformed UTF-8', () {
      expect(decodeString([0x41, 0xFF]), startsWith('A'));
    });
  });

  group('looksLikeHueBulb', () {
    test('matches the fe0f service UUID in short or long form', () {
      expect(looksLikeHueBulb(serviceUuids: [Guid('fe0f')]), isTrue);
      expect(
        looksLikeHueBulb(
          serviceUuids: [Guid('0000fe0f-0000-1000-8000-00805f9b34fb')],
        ),
        isTrue,
      );
    });

    test('matches fe0f service data', () {
      expect(
        looksLikeHueBulb(serviceUuids: [], serviceDataUuids: [Guid('fe0f')]),
        isTrue,
      );
    });

    test('matches "hue" in a name, case-insensitively', () {
      expect(
        looksLikeHueBulb(serviceUuids: [], names: ['Hue color lamp']),
        isTrue,
      );
      expect(looksLikeHueBulb(serviceUuids: [], names: ['', 'my HUE']), isTrue);
    });

    test('works from names alone (paired / connected devices)', () {
      expect(looksLikeHueBulb(names: ['Hue white lamp']), isTrue);
      expect(looksLikeHueBulb(names: ['JBL Flip 5']), isFalse);
      expect(looksLikeHueBulb(), isFalse);
    });

    test('rejects other devices', () {
      expect(
        looksLikeHueBulb(
          serviceUuids: [Guid('180d')],
          names: ['Heart Rate', ''],
        ),
        isFalse,
      );
    });
  });

  group('HueLightState', () {
    test('copyWith keeps unspecified fields', () {
      const s = HueLightState(
        on: true,
        brightness: 100,
        mireds: 370,
        xy: XyColor(0.3, 0.3),
      );
      expect(
        s.copyWith(brightness: 5),
        const HueLightState(
          on: true,
          brightness: 5,
          mireds: 370,
          xy: XyColor(0.3, 0.3),
        ),
      );
      expect(s.copyWith(), s);
    });
  });
}
