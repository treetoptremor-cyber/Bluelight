import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The four dashboard designs. Each sets the whole app's theme; the
/// dashboard also changes layout (see dashboard_page.dart).
enum AppDesign {
  clear('Clear', 'Legible and high contrast, big rows'),
  glow('Glow', 'Dark, with tiles glowing in each light’s colour'),
  rooms('Rooms', 'Warm cards per room with brightness'),
  wireframe('Wireframe', 'Minimal, compact and monochrome');

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
  };

  ThemeData theme() {
    final dark = this == glow;
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
    };
    final base = ThemeData(colorScheme: scheme).textTheme;
    final text = webFonts ? _textTheme(base) : base;

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
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
          wireframe => Colors.white,
          _ => Colors.white,
        },
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            this == wireframe ? 8 : (this == rooms ? 24 : 20),
          ),
          side: switch (this) {
            wireframe => const BorderSide(color: Colors.black87, width: 1.5),
            clear => const BorderSide(color: Color(0xFFE4E0D8)),
            glow => const BorderSide(color: Color(0xFF2E2B27)),
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
    };
  }
}
