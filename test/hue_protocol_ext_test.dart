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

    test('parses a read-back of what we store', () {
      for (final kind in BulbScheduleKind.values) {
        final payload = buildSchedulePayload(
          kind: kind,
          at: at,
          fade: const Duration(minutes: 15),
          title: 'HBR Evening',
          uuid: uuid,
        );
        // 02 00 <id> <len> .. .. .. <body = payload from byte 3>
        final body = payload.sublist(3);
        final readback = [
          0x02,
          0x00,
          0x2a,
          0x00,
          body.length,
          0,
          0,
          0,
          ...body,
        ];
        final s = parseScheduleReadback(readback)!;
        expect(s.id, 42);
        expect(s.title, 'HBR Evening');
        expect(s.wake, kind == BulbScheduleKind.wake);
        expect(s.fade, const Duration(minutes: 15));
        expect(s.enabled, isTrue);
        expect(s.at.toUtc(), at, reason: '$kind set time');
      }
      // A read-back one byte shorter before the title (as the reference
      // decoder's offsets suggest) still yields the title.
      final p = buildSchedulePayload(
        kind: BulbScheduleKind.sleep,
        at: at,
        fade: Duration.zero,
        title: 'Go to sleep',
        uuid: uuid,
      );
      final shorter = [...p.sublist(3, 47), ...p.sublist(48)];
      final rb = [0x02, 0x00, 0x07, 0x00, shorter.length, 0, 0, 0, ...shorter];
      expect(parseScheduleReadback(rb)!.title, 'Go to sleep');
      expect(parseScheduleReadback([0x02, 0x00, 0x01]), isNull);
    });

    test('parses a real read-back from a bulb (a routine that ran)', () {
      // Kitchen 1, schedule 4: "HBR Lights off", sleep at 19:01, fired.
      const hexText =
          '02 00 04 00 3e 00 00 00 00 00 01 2c 43 bc 6a 00 0e 01 01 00 02 01 '
          '01 03 02 4c 02 05 02 00 00 26 01 37 ac b4 28 c1 1c 07 b3 67 29 ee '
          '6f ae 85 db d1 01 ff ff ff ff 0e 48 42 52 20 4c 69 67 68 74 73 20 '
          '6f 66 66 01';
      final bytes = [
        for (final b in hexText.split(' ')) int.parse(b, radix: 16),
      ];
      final s = parseScheduleReadback(bytes)!;
      expect(s.id, 4);
      expect(s.title, 'HBR Lights off');
      expect(s.wake, isFalse);
      expect(s.fade, Duration.zero);
      expect(s.ran, isTrue);
      expect(s.enabled, isFalse);
      expect(
        s.start.toUtc(),
        DateTime.fromMillisecondsSinceEpoch(0x6abc432c * 1000, isUtc: true),
      );
    });
  });
}
