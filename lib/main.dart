import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'hub.dart';
import 'routine_runner.dart';
import 'store.dart';
import 'ui/common.dart';
import 'ui/dashboard_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  final hub = HueHub(store);
  final runner = RoutineRunner(store, hub);
  runApp(
    AppScope(store: store, hub: hub, runner: runner, child: const HueBleApp()),
  );
}

class HueBleApp extends StatelessWidget {
  const HueBleApp({super.key});

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.symmetric(vertical: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hue BLE Remote',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const DashboardPage(),
    );
  }
}
