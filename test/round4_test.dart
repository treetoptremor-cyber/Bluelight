import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/color_utils.dart';
import 'package:hue_ble_remote/hue_protocol_ext.dart';
import 'package:hue_ble_remote/natural_light.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('effects', () {
    test('encodes effect and speed after the light state', () {
      expect(
        hex(encodeCombinedState(on: true, effect: HueEffect.candle)),
        '010101'
        '060101',
      );
      expect(
        hex(encodeCombinedState(effect: HueEffect.prism, effectSpeed: 255)),
        '060103'
        '0801ff',
      );
    });

    test('ids round trip; unknown ids are none', () {
      for (final e in HueEffect.values) {
        expect(HueEffect.fromId(e.id), e);
      }
      expect(HueEffect.fromId(0x7f), HueEffect.none);
    });

    test('reads the effect from a combined notification', () {
      // on, bri, mireds, effect candle, speed 128 (16 bytes).
      final withEffect = [
        0x01, 0x01, 0x01, 0x02, 0x01, 0x80, 0x03, 0x02, 0x72, 0x01, //
        0x06, 0x01, 0x01, 0x08, 0x01, 0x80,
      ];
      expect(decodeCombinedEffect(withEffect), HueEffect.candle);
      expect(decodeCombinedEffect(withEffect.sublist(0, 10)), isNull);
    });

    test('TLV decoding tolerates a truncated tail', () {
      expect(decodeTlv([0x01, 0x01, 0x01, 0x02, 0x05]), {
        0x01: [0x01],
      });
    });
  });

  group('power-on behaviour', () {
    test('matches the documented example', () {
      // "on, brightness fe, temperature f4, colour ffffffff = use white"
      expect(
        hex(encodePowerOn(const PowerOnState(on: true, mireds: 0xf4))),
        '010101'
        '0201fe'
        '0302f400'
        '0404ffffffff',
      );
    });

    test('colour and off round trip', () {
      const colour = PowerOnState(
        on: true,
        brightness: 100,
        mireds: 300,
        xy: XyColor(0.5, 0.25),
      );
      final back = decodePowerOn(encodePowerOn(colour))!;
      expect(back.on, isTrue);
      expect(back.brightness, 100);
      expect(back.xy!.x, closeTo(0.5, 1 / 65535));
      expect(back.xy!.y, closeTo(0.25, 1 / 65535));

      const off = PowerOnState(on: false);
      expect(decodePowerOn(encodePowerOn(off)), off);
      expect(decodePowerOn([0x02, 0x01, 0xfe]), isNull);
    });
  });

  group('natural light', () {
    DateTime at(int h, [int m = 0]) => DateTime(2026, 9, 30, h, m);

    test('warm at night, cool at midday, warming in the evening', () {
      expect(naturalKelvin(at(2)), 2200);
      expect(naturalKelvin(at(13)), 5500);
      expect(naturalKelvin(at(21)), 2600);
      expect(naturalKelvin(at(23, 30)), 2200);
      expect(naturalKelvin(at(9)), inExclusiveRange(3800, 5000));
    });

    test('continuous and within Hue range all day', () {
      double? last;
      for (var m = 0; m < 24 * 60; m++) {
        final k = naturalKelvin(DateTime(2026, 9, 30, m ~/ 60, m % 60));
        expect(k, inInclusiveRange(2200, 6500));
        if (last != null) expect((k - last).abs(), lessThan(30));
        last = k;
      }
    });
  });
}
