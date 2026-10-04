import 'package:flutter/material.dart';

import 'bulb_scheduler.dart';
import 'diagnostics.dart';
import 'hub.dart';
import 'routine_runner.dart';
import 'store.dart';
import 'widget_bridge.dart';
import 'ui/common.dart';
import 'ui/dashboard_page.dart';
import 'ui/designs.dart';
import 'ui/target_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diagnostics.instance.init();
  final store = await AppStore.load();
  final hub = HueHub(store);
  final scheduler = BulbScheduler(store, hub);
  // Locking the phone right after saving a routine must not cut the sync
  // to the bulbs short.
  hub.beforeRelease = () async {
    if (scheduler.syncing) diag('app', 'background: finishing routine sync');
    await scheduler.idle();
  };
  final runner = RoutineRunner(store, hub, scheduler: scheduler);
  final widgets = WidgetBridge(store, hub);
  widgets.onOpen = (id) {
    if (store.group(id) == null && store.light(id) == null) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => TargetPage(targetId: id)),
    );
  };
  WidgetsBinding.instance.addPostFrameCallback((_) => widgets.openPending());
  runApp(
    AppScope(
      store: store,
      hub: hub,
      runner: runner,
      scheduler: scheduler,
      child: const BluelightApp(),
    ),
  );
}

class BluelightApp extends StatelessWidget {
  const BluelightApp({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final design = AppDesign.fromName(store.design);
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Bluelight',
          // Each design is its own look, light or dark.
          theme: design.theme(),
          themeMode: ThemeMode.light,
          themeAnimationDuration: const Duration(milliseconds: 350),
          home: const DashboardPage(),
        );
      },
    );
  }
}
