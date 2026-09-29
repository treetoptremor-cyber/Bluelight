import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/color_utils.dart';
import 'package:hue_ble_remote/hue_protocol_ext.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('combined state', () {
    test('brightness 254 over 5 s (HueBLE example)', () {
      expect(
        hex(
          encodeCombinedState(
            brightness: 254,
            transition: const Duration(seconds: 5),
          ),
        ),
        '0201fe05023200',
      );
    });

    test('all fields, in tag order', () {
      expect(
        hex(
          encodeCombinedState(
            on: true,
            brightness: 128,
            mireds: 370,
            xy: const XyColor(0.5, 0.25),
            transition: const Duration(milliseconds: 400),
          ),
        ),
        '010101'
        '020180'
        '03027201'
        '040400800040'
        '05020400',
      );
    });

    test('off with a long fade; values clamp', () {
      expect(
        hex(
          encodeCombinedState(on: false, transition: const Duration(hours: 3)),
        ),
        '010100'
        '0502ffff',
      );
      expect(
        hex(encodeCombinedState(brightness: 0, mireds: 900)),
        '020101'
        '0302f401',
      );
    });
  });

  group('schedules', () {
    final uuid = List<int>.generate(16, (i) => i);
    final at = DateTime.fromMillisecondsSinceEpoch(
      1790000000 * 1000,
      isUtc: true,
    );

    // Expected bytes come from build_standard_schedule_payload in the
    // capture-derived reference script, with the same inputs.
    test('sleep payload matches the reference script', () {
      final p = buildSchedulePayload(
        kind: BulbScheduleKind.sleep,
        at: at,
        fade: const Duration(seconds: 1800),
        title: 'Go to sleep',
        uuid: uuid,
      );
      expect(
        hex(p),
        '01ffff000100803bb16a000e01010002010103024c02050250462301'
        '000102030405060708090a0b0c0d0e0f01ffffffff0b476f20746f20736c65657001',
      );
    });

    test('wake payload stores the fade start and matches the reference', () {
      final p = buildSchedulePayload(
        kind: BulbScheduleKind.wake,
        at: at,
        fade: const Duration(seconds: 600),
        title: 'Wake up',
        uuid: uuid,
      );
      expect(
        hex(p),
        '01ffff0001002839b16a000e0101010201fe0302bf01050270171f01'
        '000102030405060708090a0b0c0d0e0f00ffffffff0757616b6520757001',
      );
    });

    test('wake can target another brightness and white', () {
      final p = buildSchedulePayload(
        kind: BulbScheduleKind.wake,
        at: at,
        fade: Duration.zero,
        title: 'x',
        uuid: uuid,
        brightness: 100,
        mireds: 250,
      );
      // on, bri 0x64, mireds 0x00fa, fade 0
      expect(
        hex(p.sublist(10, 26)),
        '000e010101020164030 2fa0005020000'.replaceAll(' ', ''),
      );
    });

    test('titles are ASCII only', () {
      final p = buildSchedulePayload(
        kind: BulbScheduleKind.sleep,
        at: at,
        fade: Duration.zero,
        title: 'Café ☕',
        uuid: uuid,
      );
      // "Caf " -> 4 bytes, then the trailing enabled byte.
      expect(hex(p.sublist(p.length - 6)), '04436166200 1'.replaceAll(' ', ''));
    });

    test('bad uuid or fade is rejected', () {
      expect(
        () => buildSchedulePayload(
          kind: BulbScheduleKind.sleep,
          at: at,
          fade: Duration.zero,
          title: '',
          uuid: const [1, 2],
        ),
        throwsArgumentError,
      );
      expect(
        () => buildSchedulePayload(
          kind: BulbScheduleKind.sleep,
          at: at,
          fade: const Duration(hours: 3),
          title: '',
          uuid: uuid,
        ),
        throwsArgumentError,
      );
    });

    test('delete, list and clock payloads', () {
      expect(hex(buildScheduleDelete(0x1234)), '033412');
      expect(hex(buildScheduleList()), '00');
      expect(hex(buildClockSync(at)), '80 3b b1 6a'.replaceAll(' ', ''));
    });

    test('parses replies', () {
      expect(
        (ScheduleReply.parse([
          0x01,
          0x00,
          0xff,
          0xff,
          0x07,
          0x00,
        ]) as ScheduleCreated).id,
        7,
      );
      expect(
        ScheduleReply.parse([0x01, 0x01, 0xff, 0xff, 0xff, 0xff]),
        isA<ScheduleRejected>(),
      );
      expect(
        (ScheduleReply.parse([0x03, 0x00, 0x07, 0x00]) as ScheduleDeleted).id,
        7,
      );
      expect(
        (ScheduleReply.parse([
          0x00,
          0x00,
          0x00,
          0x02,
          0x07,
          0x00,
          0x09,
          0x01,
        ]) as ScheduleList).ids,
        [7, 0x109],
      );
      expect(
        ScheduleReply.parse([0x04, 0xff, 0xff, 0x07, 0x00]),
        isA<ScheduleDone>(),
      );
      expect(ScheduleReply.parse([0x09]), isNull);
    });
  });
}
