# Hue BLE Remote

A small Flutter app for iPhone and Android that controls **Philips Hue Bluetooth
bulbs directly over Bluetooth Low Energy**, with no Hue Bridge and no account.

## What it does

- **Dashboard**: your groups and lights by name, each with a power switch.
  Details (connection status, model, what it supports, groups, Bluetooth ID,
  rename, remove) sit behind the **(i)** button. Tap a row for its controls.
- **Controls**: power, brightness, white colour temperature and colour, with
  thick gradient sliders that follow your finger and update the light about
  25 times a second. Moving a slider while the light is off turns it on.
- **Groups**: control several lights together. A light can be in several
  groups.
- **Presets**: "Save current look" stores each light's exact state (on/off,
  brightness, white or colour). Tap to apply; long-press to rename, update or
  delete.
- **Sleep timer**: dims slowly, then turns off (5–60 minutes).
- **Routines**: at a time on chosen days, turn lights on or off or apply a
  preset, optionally fading in or out over several minutes.

Everything is stored on the phone; there is no account.

### Routines run on the bulbs

Routines are stored on the bulbs' own schedules (with their clock set by the
app), so they run with the app closed and the phone away. A bulb schedule runs
once, so the app stores the next three runs of each routine and tops them up
whenever it connects. Colour presets can't be stored on a bulb, so routines
that apply one run only while the app is open. The sleep timer is stored on
the bulbs too.

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

Android 7.0 (API 24, Flutter's default minimum) or newer with Bluetooth LE.
On Android 12+ the app asks for the "Nearby devices" permission the first time
it scans; on older versions it asks for location, which Android requires for
Bluetooth scanning.

## Pairing a bulb (and keeping the Hue app working)

The bulb's control characteristics are encrypted, so the phone has to be
**paired** (bonded) with the bulb. Pairing belongs to the phone, not to an
app, and a bulb can be paired with several devices at once. **Never reset a
bulb to use it with this app**: a reset wipes all of its pairings and removes
it from the Hue app.

**Bulb set up in the Hue app on this same phone.** Nothing to do. The phone is
already paired, so Hue BLE Remote uses the same pairing and both apps keep
working. There is no pairing prompt.

**Bulb set up in the Hue app on another phone.** Let the bulb accept one more
pairing, without a reset:

1. On the phone with the Hue app, open the Philips Hue app (or the older Hue
   Bluetooth app) and go to **Settings → Voice assistants → Amazon Alexa →
   Make discoverable** (Home Assistant's `hue_ble` docs also list
   **Google Home → Make discoverable**). The bulb accepts new pairings for a
   few minutes. Menu names vary between Hue app versions.
2. On your phone, open Hue BLE Remote, tap the bulb, and accept the
   **pairing prompt**.
3. The bulb keeps working in the Hue app on the other phone.

**Brand-new bulb.** It accepts a pairing out of the box: tap it and accept the
prompt.

In all cases:

- Power the bulb on and open Hue BLE Remote with Bluetooth on. The bulb should
  appear within about 15 seconds. Bulbs the phone is already connected to
  (for example by the Hue app) or paired with are listed too, marked
  **Connected** or **Paired**, even if they are not advertising.
- The pairing prompt appears on iOS when the app first reads the bulb, and on
  Android right after connecting. Later connections reuse the pairing.

### Sharing the bulb with the Hue app

A bulb may accept only one Bluetooth connection at a time. While Hue BLE
Remote is on screen it keeps your saved lights connected; as soon as you
switch to another app it lets go of all of them, so the Hue app can connect,
and it reconnects when you come back. On the same phone both apps share one
connection, so there is no conflict.

## Troubleshooting

- **Bulb not listed**: make sure it is powered and within a few metres, then
  scan again. If the Hue app on *another* phone is open and connected to the
  bulb, close it there; the bulb may not advertise while connected. If that
  doesn't help, power-cycle the bulb (off at the wall for 5 seconds, then on).
- **Pairing fails, the prompt never appears, or "insufficient
  authentication" / "insufficient encryption" errors**: the bulb didn't accept
  a pairing from this phone. Make it discoverable in the Hue app on the phone
  it is set up with (see above) and tap **Retry** within a few minutes. If
  this phone has an old pairing for the bulb in its Bluetooth settings, forget
  that entry first. Resetting the bulb also works, but it removes the bulb
  from the Hue app, so treat it as a last resort.
- **Controls stop responding**: the bulb disconnected (out of range, power
  cut, or another phone took the connection). The app keeps trying on its
  own; the light's (i) shows the status and has **Retry now**.

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
lib/main.dart            App entry point and theme
lib/hue_ble.dart         Protocol UUIDs, value encoding, HueLight wrapper
lib/color_utils.dart     RGB <-> xy and kelvin <-> mireds conversions
lib/paced_value.dart     Paces slider writes and holds the thumb steady
lib/hub.dart             Keeps saved lights connected; group, preset, fade ops
lib/models.dart          Lights, groups, presets, routines (+ JSON)
lib/store.dart           Saves them on the phone
lib/routine_runner.dart  Runs routines at their times while the app is open
lib/ui/                  Dashboard, controls, add lights, groups, routines
test/                    Unit and widget tests
```

Run the tests with `flutter test`.

## Credits

- Scene colours: [Hypfer/hass-scene_presets](https://github.com/Hypfer/hass-scene_presets)
  (Apache-2.0), measured from the Hue app's scene gallery, cross-checked with
  [nilsreiter/home-assistant-scenes](https://github.com/nilsreiter/home-assistant-scenes)
  and [ebaauw/ph.sh](https://github.com/ebaauw/ph.sh).
- Combined light state with fade time: [flip-dots/HueBLE](https://github.com/flip-dots/HueBLE).
- On-bulb schedules and clock sync: captures by
  [luigibrancati](https://gist.github.com/luigibrancati/47442f40adf6f54b17337d8dd3794e2c)
  and the discussion in
  [shinyquagsire23's gist](https://gist.github.com/shinyquagsire23/f7907fdf6b470200702e75a30135caf3).
  The app never writes `97fe6561-0004`, reported to factory-reset a bulb.
