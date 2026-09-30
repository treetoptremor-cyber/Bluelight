import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/hub.dart';
import 'package:hue_ble_remote/main.dart';
import 'package:hue_ble_remote/models.dart';
import 'package:hue_ble_remote/routine_runner.dart';
import 'package:hue_ble_remote/store.dart';
import 'package:hue_ble_remote/ui/common.dart';
import 'package:hue_ble_remote/ui/designs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pumps the app on a store with [seed] data. Call it inside
/// `tester.runAsync` so the hub's and routine runner's timers run on the
/// real clock. Saved lights make the hub try to connect through
/// flutter_blue_plus, which has no platform in tests, so those tests only
/// check what doesn't need a connection.
Future<(AppStore, HueHub, RoutineRunner)> _pumpApp(
  WidgetTester tester, {
  Future<void> Function(AppStore store)? seed,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = await AppStore.load();
  await seed?.call(store);
  final hub = HueHub(store);
  final runner = RoutineRunner(store, hub);
  addTearDown(() {
    runner.dispose();
    hub.dispose();
  });
  await tester.pumpWidget(
    AppScope(store: store, hub: hub, runner: runner, child: const HueBleApp()),
  );
  return (store, hub, runner);
}

void main() {
  setUpAll(() => AppDesign.webFonts = false);

  testWidgets('empty dashboard offers to add lights', (tester) async {
    await tester.runAsync(() => _pumpApp(tester));
    await tester.pump();
    expect(find.text('No lights yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add lights'), findsOneWidget);
    expect(find.byTooltip('Design'), findsOneWidget);
  });

  testWidgets('dashboard shows names with an (i) and a switch', (tester) async {
    await tester.runAsync(() async {
      await _pumpApp(
        tester,
        seed: (s) async {
          await s.addLight(const SavedLight(id: 'AA:BB', name: 'Desk lamp'));
          await s.addLight(const SavedLight(id: 'CC:DD', name: 'Ceiling'));
          await s.saveGroup(
            const LightGroup(
              id: 'g1',
              name: 'Office',
              lightIds: ['AA:BB', 'CC:DD'],
            ),
          );
        },
      );
    });
    await tester.pump();
    expect(find.text('Desk lamp'), findsOneWidget);
    expect(find.text('Ceiling'), findsOneWidget);
    // Dim-all slider sits with All off at the top.
    expect(find.bySemanticsLabel('Dim all lights'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'All off'), findsOneWidget);
    expect(find.text('Office'), findsOneWidget);
    // One (i) per group and light; switches disabled until connected.
    expect(find.byTooltip('Details'), findsNWidgets(3));
    final switches = tester.widgetList<Switch>(find.byType(Switch));
    expect(switches, hasLength(3));
    expect(switches.every((s) => s.onChanged == null), isTrue);

    // Details are behind the (i).
    await tester.tap(find.byTooltip('Details').at(1));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth ID'), findsOneWidget);
    expect(find.text('Office'), findsWidgets); // listed under Groups
  });

  testWidgets('new group needs a name and a light', (tester) async {
    await tester.runAsync(() async {
      await _pumpApp(
        tester,
        seed: (s) =>
            s.addLight(const SavedLight(id: 'AA:BB', name: 'Desk lamp')),
      );
    });
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, 'Save');
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Office');
    await tester.tap(find.text('Desk lamp'));
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
  });

  testWidgets('design picker switches between all four designs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556); // iPhone size
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late AppStore store;
    await tester.runAsync(() async {
      (store, _, _) = await _pumpApp(
        tester,
        seed: (s) async {
          await s.addLight(const SavedLight(id: 'AA:BB', name: 'Desk lamp'));
          await s.saveGroup(
            const LightGroup(id: 'g1', name: 'Office', lightIds: ['AA:BB']),
          );
        },
      );
    });
    await tester.pump();
    for (final d in AppDesign.values) {
      await tester.tap(find.byTooltip('Design'));
      await tester.pumpAndSettle();
      expect(find.text(d.label), findsOneWidget);
      await tester.tap(find.text(d.label));
      await tester.pumpAndSettle();
      expect(store.design, d.name);
      // Every design still shows the names.
      expect(find.text('Desk lamp'), findsWidgets);
      expect(find.text('Office'), findsWidgets);
    }
  });

  testWidgets('FatSlider reports start, changes and end', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: FatSlider(
              value: 50,
              min: 0,
              max: 100,
              gradient: rainbow,
              dragging: false,
              onChangeStart: (v) => events.add('start'),
              onChanged: (v) => events.add('change'),
              onChangeEnd: (v) => events.add('end'),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(events.first, 'start');
    expect(events.last, 'end');
    expect(events.where((e) => e == 'change'), isNotEmpty);
  });
}
