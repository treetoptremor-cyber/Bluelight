# Hue BLE Remote

A small Flutter app for iPhone and Android that controls **Philips Hue Bluetooth
bulbs directly over Bluetooth Low Energy**, with no Hue Bridge and no account.

It does four things: find nearby Hue bulbs, pair with one, and control its
power, brightness, white colour temperature and colour. There are no scenes,
groups, schedules or accounts.

## Supported bulbs

Hue bulbs with the **Bluetooth logo** on the bulb or box (sold from 2019
onwards). Controls adapt to what the bulb supports:

| Bulb | Power | Brightness | White temperature | Colour |
|---|---|---|---|---|
| Hue White | ✓ | ✓ | | |
| Hue White Ambiance | ✓ | ✓ | ✓ | |
| Hue White and Colour Ambiance | ✓ | ✓ | ✓ | ✓ |

Older Zigbee-only Hue bulbs (no Bluetooth logo) need a Hue Bridge and won't
show up.

## Build and run

1. Install Flutter (stable, 3.47 or newer):
   <https://docs.flutter.dev/get-started/install>
2. Fetch dependencies:
   ```bash
   flutter pub get
   ```
3. Plug in a **physical** phone and run:
   ```bash
   flutter run
   ```
   Simulators and emulators have no Bluetooth radio, so the app can only find
   bulbs on a real device.

### iOS signing

To run on an iPhone, open `ios/Runner.xcworkspace` in Xcode, select the
**Runner** target → **Signing & Capabilities**, and choose your team (a free
Apple ID works for personal devices). You may also need to change the bundle
identifier to something unique.

### Android

Android 7.0 (API 24, Flutter's default minimum) or newer with Bluetooth LE. On Android 12+ the app asks
for the "Nearby devices" permission the first time it scans; on older versions
it asks for location, which Android requires for Bluetooth scanning.

## Pairing a bulb

The bulb's control characteristics are encrypted, so the phone has to be
**bonded** (paired) with the bulb.

1. **If the bulb was set up in the official Hue Bluetooth app**, reset it from
   that app first (Settings → the bulb → Reset). A bulb only accepts a new
   pairing after a reset. Brand-new bulbs accept one out of the box.
2. Power the bulb on and open Hue BLE Remote with Bluetooth on. The bulb
   should appear in the list within about 15 seconds.
3. Tap the bulb. Accept the **pairing prompt** the phone shows (on iOS it
   appears when the app first reads the bulb; on Android right after
   connecting).
4. The controls appear with the bulb's current state. Later connections reuse
   the pairing, so there is no prompt.

## Troubleshooting

- **Bulb not listed**: power-cycle it (off at the wall for 5 seconds, then on)
  and scan again. Keep the phone within a few metres. If it is paired with
  another phone or the Hue app, reset it there first.
- **Pairing fails, or the prompt never appears**: reset the bulb in the Hue
  Bluetooth app, then forget it in the phone's Bluetooth settings, and try
  again.
- **"Insufficient authentication" / "insufficient encryption" errors**: the
  bond was not established. Same fix as above: reset the bulb, forget it in
  the phone's Bluetooth settings, and pair again.
- **Controls stop responding**: the bulb disconnected (out of range or power
  cut). Tap **Reconnect**.

## Protocol

The Hue Bluetooth protocol is not officially documented. This app uses the
reverse-engineered protocol also used by the
[HueBLE](https://github.com/flip-dots/HueBLE) Python library and the Home
Assistant `hue_ble` integration. All UUIDs live in
[`lib/hue_ble.dart`](lib/hue_ble.dart).

| Purpose | UUID | Encoding |
|---|---|---|
| Advertised service (Signify), used to recognise Hue bulbs when scanning | `0000fe0f-0000-1000-8000-00805f9b34fb` (16-bit `fe0f`) | — |
| Light control service | `932c32bd-0000-47a2-835a-a8d455b859dd` | — |
| Power | `932c32bd-0002-47a2-835a-a8d455b859dd` | 1 byte: `0x00` off, `0x01` on. Read / write / notify |
| Brightness | `932c32bd-0003-47a2-835a-a8d455b859dd` | 1 byte: 1–254. Read / write / notify |
| Colour temperature | `932c32bd-0004-47a2-835a-a8d455b859dd` | uint16 little-endian, mireds, 153–500 (some bulbs stop at 454). Read / write / notify |
| Colour (CIE 1931 xy) | `932c32bd-0005-47a2-835a-a8d455b859dd` | 4 bytes: x then y, each uint16 little-endian of `round(value * 0xFFFF)`. Read / write / notify |
| Bulb name | `97fe6561-0003-4f62-86e9-b71ee2da3d22` | UTF-8 string, read (optional; falls back to the advertised name) |
| Model number (Device Information) | `00002a24-0000-1000-8000-00805f9b34fb` | UTF-8 string, read |

Writing a colour temperature switches the bulb to white mode; writing xy
switches it to colour mode. White-only bulbs have no colour temperature or
colour characteristic, and White Ambiance bulbs have no colour characteristic;
the app hides those controls.

Colours are converted between sRGB and CIE xy with Philips' published
Wide RGB D65 formulas (`lib/color_utils.dart`).

## Project layout

```
lib/main.dart          App entry point and theme
lib/scan_page.dart     Scan for Hue bulbs and list them
lib/light_page.dart    Connect to one bulb and show its controls
lib/hue_ble.dart       Protocol UUIDs, value encoding, HueLight wrapper
lib/color_utils.dart   RGB <-> xy and kelvin <-> mireds conversions
test/                  Unit tests for the encoding and colour maths
```

Run the tests with `flutter test`.
