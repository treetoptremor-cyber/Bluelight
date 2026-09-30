import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The four dashboard designs. Each sets the whole app's theme; the
/// dashboard also changes layout (see dashboard_page.dart).
enum AppDesign {
  clear('Clear', 'Legible and high contrast, big rows'),
  glow('Glow', 'Dark, with tiles glowing in each light’s colour'),
  rooms('Rooms', 'Warm cards per room with brightness'),
  wireframe('Wireframe', 'Minimal, compact and monochrome'),
  lumen('Lumen', 'A living sky with glass light pillars you drag to dim');

  const AppDesign(this.label, this.description);

  final String label;
  final String description;

  /// Off in tests, where fonts can't be fetched.
  static bool webFonts = true;

  static AppDesign fromName(String? name) =>
      values.asNameMap()[name] ?? AppDesign.clear;

  /// Colours for the picker's preview swatch: background, card, accent.
  (Color, Color, Color) get swatch => switch (this) {
    clear => (const Color(0xFFF4F2EE), Colors.white, const Color(0xFF9A3F0E)),
    glow => (
      const Color(0xFF0E0D0C),
      const Color(0xFFFF9A45),
      const Color(0xFFB03A8A),
    ),
    rooms => (const Color(0xFFF7F1E8), Colors.white, const Color(0xFFB8561A)),
    wireframe => (Colors.white, const Color(0xFFEEEEEE), Colors.black87),
    lumen => (
      const Color(0xFF2A2160),
      const Color(0x55FFFFFF),
      const Color(0xFFFFB46B),
    ),
  };

  /// Dark designs get light text and dark controls.
  bool get isDark => this == glow || this == lumen;

  ThemeData theme() {
    final dark = isDark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final scheme = switch (this) {
      clear => ColorScheme.fromSeed(
        seedColor: const Color(0xFF9A3F0E),
        brightness: brightness,
      ).copyWith(surface: const Color(0xFFF4F2EE)),
      glow => ColorScheme.fromSeed(
        seedColor: const Color(0xFFFF9A45),
        brightness: brightness,
      ).copyWith(surface: const Color(0xFF0E0D0C)),
      rooms => ColorScheme.fromSeed(
        seedColor: const Color(0xFFB8561A),
        brightness: brightness,
      ).copyWith(surface: const Color(0xFFF7F1E8)),
      wireframe => ColorScheme.fromSeed(
        seedColor: Colors.grey,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(surface: Colors.white),
      lumen => ColorScheme.fromSeed(
        seedColor: const Color(0xFF7B6CF6),
        brightness: brightness,
      ).copyWith(surface: const Color(0xFF15122C)),
    };
    final base = ThemeData(colorScheme: scheme).textTheme;
    final text = webFonts ? _textTheme(base) : base;

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: this == lumen ? Colors.transparent : scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        color: switch (this) {
          glow => const Color(0xFF1A1816),
          lumen => const Color(0x26FFFFFF),
          _ => Colors.white,
        },
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(switch (this) {
            wireframe => 8,
            rooms || lumen => 24,
            _ => 20,
          }),
          side: switch (this) {
            wireframe => const BorderSide(color: Colors.black87, width: 1.5),
            clear => const BorderSide(color: Color(0xFFE4E0D8)),
            glow => const BorderSide(color: Color(0xFF2E2B27)),
            lumen => const BorderSide(color: Color(0x33FFFFFF)),
            rooms => BorderSide.none,
          },
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

  TextTheme _textTheme(TextTheme base) {
    TextTheme headings(TextTheme body, TextTheme heading) => body.copyWith(
      displayLarge: heading.displayLarge,
      displayMedium: heading.displayMedium,
      displaySmall: heading.displaySmall,
      headlineLarge: heading.headlineLarge,
      headlineMedium: heading.headlineMedium,
      headlineSmall: heading.headlineSmall,
      titleLarge: heading.titleLarge,
    );
    return switch (this) {
      clear => GoogleFonts.atkinsonHyperlegibleTextTheme(base),
      glow => headings(
        GoogleFonts.atkinsonHyperlegibleTextTheme(base),
        GoogleFonts.soraTextTheme(base),
      ),
      rooms => headings(
        GoogleFonts.atkinsonHyperlegibleTextTheme(base),
        GoogleFonts.frauncesTextTheme(base),
      ),
      wireframe => GoogleFonts.ibmPlexMonoTextTheme(base),
      lumen => headings(
        GoogleFonts.atkinsonHyperlegibleTextTheme(base),
        GoogleFonts.spaceGroteskTextTheme(base),
      ),
    };
  }
}

/// The Lumen sky for [time]: (top, bottom) colours through the day —
/// indigo night, peach dawn, soft blue day, amber-rose dusk.
LinearGradient skyGradient(DateTime time) {
  const keys = <(double, Color, Color)>[
    (0, Color(0xFF0B0A1F), Color(0xFF1B1640)),
    (5, Color(0xFF15123A), Color(0xFF2E2358)),
    (6.5, Color(0xFF3B2F6B), Color(0xFFE88F78)),
    (8, Color(0xFF4F7FC4), Color(0xFFF2B98E)),
    (12, Color(0xFF2F6CC0), Color(0xFF8FBDE8)),
    (16, Color(0xFF3E6DB5), Color(0xFFE9B98A)),
    (18.5, Color(0xFF45296A), Color(0xFFE9794F)),
    (20, Color(0xFF1E1A45), Color(0xFF6B3E6E)),
    (22, Color(0xFF0E0C26), Color(0xFF221B48)),
    (24, Color(0xFF0B0A1F), Color(0xFF1B1640)),
  ];
  final h = time.hour + time.minute / 60;
  var i = 1;
  while (i < keys.length - 1 && keys[i].$1 < h) {
    i++;
  }
  final (h0, t0, b0) = keys[i - 1];
  final (h1, t1, b1) = keys[i];
  final t = ((h - h0) / (h1 - h0)).clamp(0.0, 1.0);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color.lerp(t0, t1, t)!, Color.lerp(b0, b1, t)!],
  );
}
