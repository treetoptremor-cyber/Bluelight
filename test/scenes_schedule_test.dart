import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/bulb_scheduler.dart';
import 'package:hue_ble_remote/color_utils.dart';
import 'package:hue_ble_remote/hue_ble.dart';
import 'package:hue_ble_remote/hue_protocol_ext.dart';
import 'package:hue_ble_remote/models.dart';
import 'package:hue_ble_remote/scenes.dart';
import 'package:hue_ble_remote/scenes_data.dart';
import 'package:hue_ble_remote/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('scenes', () {
    test('library has the Hue whites and colour gallery', () {
      expect(hueScenes.length, greaterThan(140));
      final names = {for (final s in hueScenes) s.name};
      expect(
        names,
        containsAll([
          'Energize',
          'Concentrate',
          'Read',
          'Relax',
          'Nightlight',
          'Savanna sunset',
          'Tropical twilight',
          'Arctic aurora',
          'Candlelit dinner',
        ]),
      );
      for (final s in hueScenes) {
        expect(s.colors, isNotEmpty, reason: s.name);
        expect(s.brightness, inInclusiveRange(1, 254), reason: s.name);
        for (final c in s.colors) {
          if (c.isWhite) {
            expect(
              c.ct,
              inInclusiveRange(minMireds, maxMireds),
              reason: s.name,
            );
          } else {
            expect(c.x, inInclusiveRange(0, 1), reason: s.name);
            expect(c.y, inInclusiveRange(0, 1), reason: s.name);
          }
        }
      }
    });

    test('palette is spread over lights in turn', () {
      final scene = hueScenes.firstWhere((s) => s.name == 'Savanna sunset');
      const color = LightAbilities(color: true, white: true);
      final looks = sceneLooks(scene, {
        for (var i = 0; i < 7; i++) 'l$i': color,
      });
      expect(looks['l0']!.xy, scene.colors[0].xy);
      expect(looks['l1']!.xy, scene.colors[1].xy);
      expect(looks['l5']!.xy, scene.colors[0].xy);
      expect(
        looks.values.every((l) => l.on && l.mode == HueMode.color),
        isTrue,
      );
      expect(looks['l0']!.brightness, scene.brightness);
    });

    test('lights without colour get the nearest white', () {
      final scene = hueScenes.firstWhere((s) => s.name == 'Savanna sunset');
      final looks = sceneLooks(scene, {
        'ambiance': const LightAbilities(color: false, white: true),
        'white': const LightAbilities(color: false, white: false),
      });
      expect(looks['ambiance']!.mode, HueMode.white);
      // A pale yellow (~3600 K) -> warmer than neutral 4000 K (250).
      expect(looks['ambiance']!.mireds, greaterThan(250));
      expect(looks['white']!.mireds, isNull);
      expect(looks['white']!.on, isTrue);
    });

    test('xyToMireds is close for Planckian whites', () {
      // 2732 K (Hue "Bright") and 6500 K.
      expect(xyToMireds(const XyColor(0.4596, 0.4105)), closeTo(366, 8));
      expect(xyToMireds(const XyColor(0.3127, 0.3290)), closeTo(154, 6));
    });
  });

  group('fade-in timing', () {
    const wake = Routine(
      id: 'w',
      name: 'Wake',
      targetId: 't',
      minuteOfDay: 7 * 60,
      weekdays: Routine.allWeek,
      action: RoutineAction.turnOn,
      fadeMinutes: 30,
    );

    test('fade-in starts early so it is done at the set time', () {
      final day = DateTime(2026, 9, 30);
      expect(
        wake.isDue(day.add(const Duration(hours: 6, minutes: 29))),
        isFalse,
      );
      expect(
        wake.dueOccurrence(day.add(const Duration(hours: 6, minutes: 30))),
        day.add(const Duration(hours: 7)),
      );
    });

    test('a fade-in can start the evening before', () {
      final r = wake.copyWith(minuteOfDay: 10); // 00:10, fade 30 -> 23:40
      final eve = DateTime(2026, 9, 30, 23, 40);
      expect(r.dueOccurrence(eve), DateTime(2026, 10, 1, 0, 10));
    });

    test('fade-out starts at the set time', () {
      final off = wake.copyWith(action: RoutineAction.turnOff);
      final day = DateTime(2026, 9, 30);
      expect(
        off.isDue(day.add(const Duration(hours: 6, minutes: 30))),
        isFalse,
      );
      expect(off.isDue(day.add(const Duration(hours: 7))), isTrue);
    });

    test('upcoming lists the next set times', () {
      final r = wake.copyWith(weekdays: {DateTime.monday, DateTime.friday});
      expect(r.upcoming(DateTime(2026, 9, 30, 12), 3), [
        DateTime(2026, 10, 2, 7),
        DateTime(2026, 10, 5, 7),
        DateTime(2026, 10, 9, 7),
      ]);
    });
  });

  group('bulb schedule plan', () {
    late AppStore store;
    final light = HueLight(BluetoothDevice.fromId('AA:BB'));
    final now = DateTime(2026, 9, 30, 12);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await AppStore.load();
      await store.addLight(const SavedLight(id: 'AA:BB', name: 'Lamp'));
      await store.saveGroup(
        const LightGroup(id: 'g', name: 'Room', lightIds: ['AA:BB']),
      );
    });

    List<PlannedSchedule> plan() => BulbScheduler.plan(
      store: store,
      lightId: 'AA:BB',
      light: light,
      now: now,
    );

    test('turn off -> sleep, next 3 runs, via group', () async {
      await store.saveRoutine(
        const Routine(
          id: 'r',
          name: 'Night',
          targetId: 'g',
          minuteOfDay: 23 * 60,
          weekdays: Routine.allWeek,
          action: RoutineAction.turnOff,
          fadeMinutes: 20,
        ),
      );
      final p = plan();
      expect(p, hasLength(BulbScheduler.occurrences));
      expect(p.first.kind, BulbScheduleKind.sleep);
      expect(p.first.at, DateTime(2026, 9, 30, 23));
      expect(p.first.fade, const Duration(minutes: 20));
      expect(p.first.title, startsWith(BulbScheduler.titlePrefix));
    });

    test('white preset -> wake with its brightness and white', () async {
      await store.savePreset(
        const Preset(
          id: 'p',
          name: 'Read',
          scopeId: 'AA:BB',
          looks: {'AA:BB': LightLook(on: true, brightness: 200, mireds: 300)},
        ),
      );
      await store.saveRoutine(
        const Routine(
          id: 'r',
          name: 'Morning',
          targetId: 'AA:BB',
          minuteOfDay: 7 * 60,
          weekdays: Routine.allWeek,
          action: RoutineAction.preset,
          presetId: 'p',
          fadeMinutes: 10,
        ),
      );
      final p = plan().first;
      expect(p.kind, BulbScheduleKind.wake);
      expect(p.brightness, 200);
      expect(p.mireds, 300);
      expect(p.at, DateTime(2026, 10, 1, 7));
    });

    test('disabled routines and other lights are skipped', () async {
      await store.addLight(const SavedLight(id: 'CC', name: 'Other'));
      await store.saveRoutine(
        const Routine(
          id: 'a',
          name: 'Off',
          targetId: 'CC',
          minuteOfDay: 0,
          weekdays: Routine.allWeek,
          action: RoutineAction.turnOff,
        ),
      );
      await store.saveRoutine(
        const Routine(
          id: 'b',
          name: 'Off',
          targetId: 'AA:BB',
          minuteOfDay: 0,
          weekdays: Routine.allWeek,
          action: RoutineAction.turnOff,
          enabled: false,
        ),
      );
      expect(plan(), isEmpty);
    });

    test('a wake whose fade would already have started is skipped', () async {
      await store.saveRoutine(
        const Routine(
          id: 'r',
          name: 'Soon',
          targetId: 'AA:BB',
          minuteOfDay: 12 * 60 + 10, // 12:10, fade 30 -> started 11:40
          weekdays: Routine.allWeek,
          action: RoutineAction.turnOn,
          fadeMinutes: 30,
        ),
      );
      final p = plan();
      expect(p.first.at, DateTime(2026, 10, 1, 12, 10));
    });
  });
}
