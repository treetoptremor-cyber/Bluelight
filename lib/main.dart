import 'package:flutter/material.dart';

import 'scan_page.dart';

void main() {
  runApp(const HueBleApp());
}

class HueBleApp extends StatelessWidget {
  const HueBleApp({super.key});

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: brightness,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hue BLE Remote',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const ScanPage(),
    );
  }
}
