/// "Natural light": the white a light should have at a time of day, roughly
/// following daylight: candle-warm at night, cool around midday, warming
/// through the evening.
library;

/// (minute of day, kelvin) points; linear in between, wrapping at midnight.
const naturalCurve = <(int, double)>[
  (0, 2200),
  (5 * 60, 2200),
  (6 * 60 + 30, 2700),
  (8 * 60, 3800),
  (10 * 60, 5000),
  (13 * 60, 5500),
  (16 * 60, 5000),
  (18 * 60, 4000),
  (19 * 60 + 30, 3000),
  (21 * 60, 2600),
  (22 * 60 + 30, 2200),
];

/// Kelvin for [time]'s time of day.
double naturalKelvin(DateTime time) {
  final m = time.hour * 60 + time.minute + time.second / 60;
  for (var i = 1; i < naturalCurve.length; i++) {
    final (m1, k1) = naturalCurve[i];
    if (m <= m1) {
      final (m0, k0) = naturalCurve[i - 1];
      return k0 + (k1 - k0) * (m - m0) / (m1 - m0);
    }
  }
  // After the last point: hold until midnight (curve starts at the same).
  return naturalCurve.last.$2;
}
