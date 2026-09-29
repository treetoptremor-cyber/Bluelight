import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/color_utils.dart';
import 'package:hue_ble_remote/hue_ble.dart';
import 'package:hue_ble_remote/models.dart';
import 'package:hue_ble_remote/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const colorLook = LightLook(
    on: true,
    brightness: 200,
    mode: HueMode.color,
    mireds: 370,
    xy: XyColor(0.7, 0.3),
  );

  group('JSON round trips', () {
    test('LightLook', () {
      expect(LightLook.fromJson(colorLook.toJson()), colorLook);
      const white = LightLook(on: false, brightness: 1);
      expect(LightLook.fromJson(white.toJson()), white);
    });

    test('LightLook from a state', () {
      const s = HueLightState(on: true, brightness: 10, mireds: 200);
      expect(
        LightLook.fromState(s),
        const LightLook(on: true, brightness: 10, mireds: 200),
      );
    });

    test('Preset', () {
      final p = Preset(
        id: 'p1',
        name: 'Movie',
        scopeId: 'g1',
        looks: const {'a': colorLook},
      );
      final back = Preset.fromJson(p.toJson());
      expect(back.name, 'Movie');
      expect(back.scopeId, 'g1');
      expect(back.looks, {'a': colorLook});
    });

    test('Routine', () {
      const r = Routine(
        id: 'r1',
        name: 'Wake up',
        targetId: 'g1',
        minuteOfDay: 7 * 60 + 30,
        weekdays: {1, 2, 3, 4, 5},
        action: RoutineAction.preset,
        presetId: 'p1',
        fadeMinutes: 15,
      );
      final back = Routine.fromJson(r.toJson());
      expect(back.toJson(), r.toJson());
    });

    test('tolerates junk', () {
      final r = Routine.fromJson({
        'id': 'x',
        'minute': 99999,
        'days': [0, 3, 9, 'a'],
        'action': 'nope',
        'fade': -4,
      });
      expect(r.minuteOfDay, 24 * 60 - 1);
      expect(r.weekdays, {3});
      expect(r.action, RoutineAction.turnOn);
      expect(r.fadeMinutes, 0);
    });
  });

  group('Routine timing', () {
    // Wednesday 2026-09-30.
    final wed = DateTime(2026, 9, 30);
    const r = Routine(
      id: 'r',
      name: 'r',
      targetId: 't',
      minuteOfDay: 7 * 60,
      weekdays: {DateTime.wednesday, DateTime.friday},
      action: RoutineAction.turnOn,
    );

    test('due within the window after its time, once', () {
      expect(r.isDue(wed.add(const Duration(hours: 6, minutes: 59))), isFalse);
      expect(r.isDue(wed.add(const Duration(hours: 7))), isTrue);
      expect(r.isDue(wed.add(const Duration(hours: 7, minutes: 1))), isTrue);
      expect(r.isDue(wed.add(const Duration(hours: 7, minutes: 2))), isFalse);
      expect(
        r.isDue(
          wed.add(const Duration(hours: 7, minutes: 1)),
          lastRun: wed.add(const Duration(hours: 7)),
        ),
        isFalse,
      );
      expect(
        r.isDue(
          wed.add(const Duration(hours: 7)),
          lastRun: wed.subtract(const Duration(days: 2)),
        ),
        isTrue,
      );
    });

    test('not due on other days or when disabled', () {
      final thu = wed.add(const Duration(days: 1, hours: 7));
      expect(r.isDue(thu), isFalse);
      expect(
        r.copyWith(enabled: false).isDue(wed.add(const Duration(hours: 7))),
        isFalse,
      );
    });

    test('next run', () {
      expect(r.nextRun(wed), wed.add(const Duration(hours: 7)));
      expect(
        r.nextRun(wed.add(const Duration(hours: 8))),
        DateTime(2026, 10, 2, 7),
      );
      // Friday after 7 -> next Wednesday.
      expect(r.nextRun(DateTime(2026, 10, 2, 9)), DateTime(2026, 10, 7, 7));
      expect(r.copyWith(weekdays: {}).nextRun(wed), isNull);
    });
  });

  group('AppStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('persists and reloads', () async {
      final s = await AppStore.load();
      await s.addLight(const SavedLight(id: 'a', name: 'Desk'));
      await s.addLight(const SavedLight(id: 'b', name: 'Lamp'));
      await s.saveGroup(
        const LightGroup(id: 'g', name: 'Office', lightIds: ['a', 'b']),
      );
      await s.markRun('r', DateTime(2026, 9, 30, 7));

      final again = await AppStore.load();
      expect(again.lights.map((l) => l.name), ['Desk', 'Lamp']);
      expect(again.group('g')!.lightIds, ['a', 'b']);
      expect(again.lastRun('r'), DateTime(2026, 9, 30, 7));
      expect(again.nameOf('g'), 'Office');
      expect(again.lightIdsFor('g'), ['a', 'b']);
      expect(again.lightIdsFor('a'), ['a']);
      expect(again.lightIdsFor('zzz'), isEmpty);
    });

    test('removing a light cleans up groups, presets and routines', () async {
      final s = await AppStore.load();
      await s.addLight(const SavedLight(id: 'a', name: 'A'));
      await s.addLight(const SavedLight(id: 'b', name: 'B'));
      await s.saveGroup(
        const LightGroup(id: 'g', name: 'G', lightIds: ['a', 'b']),
      );
      await s.savePreset(
        const Preset(
          id: 'pg',
          name: 'group',
          scopeId: 'g',
          looks: {'a': colorLook, 'b': colorLook},
        ),
      );
      await s.savePreset(
        const Preset(
          id: 'pa',
          name: 'a',
          scopeId: 'a',
          looks: {'a': colorLook},
        ),
      );
      await s.saveRoutine(
        const Routine(
          id: 'ra',
          name: 'a',
          targetId: 'a',
          minuteOfDay: 0,
          weekdays: Routine.allWeek,
          action: RoutineAction.turnOff,
        ),
      );

      await s.removeLight('a');
      expect(s.group('g')!.lightIds, ['b']);
      expect(s.preset('pa'), isNull);
      expect(s.preset('pg')!.looks.keys, ['b']);
      expect(s.routines, isEmpty);
    });

    test('removing a preset drops routines that use it', () async {
      final s = await AppStore.load();
      await s.savePreset(
        const Preset(id: 'p', name: 'p', scopeId: 'a', looks: {}),
      );
      await s.saveRoutine(
        const Routine(
          id: 'r',
          name: 'r',
          targetId: 'a',
          minuteOfDay: 0,
          weekdays: Routine.allWeek,
          action: RoutineAction.preset,
          presetId: 'p',
        ),
      );
      await s.removePreset('p');
      expect(s.routines, isEmpty);
    });

    test('ids are unique', () {
      final ids = {for (var i = 0; i < 200; i++) newId('g')};
      expect(ids, hasLength(200));
      expect(ids.every((id) => id.startsWith('g_')), isTrue);
    });
  });
}
