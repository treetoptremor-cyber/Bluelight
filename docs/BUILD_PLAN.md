# Build plan: Hue BLE Remote (Flutter app for Philips Hue Bluetooth bulbs)

## Status

- Step 1 is done: this repository already contains the untouched `flutter create` scaffold (Flutter 3.47.5), which passes `flutter analyze` and `flutter test`. Clone this repo and start at step 2. The counter test in `test/widget_test.dart` is still there; delete it as part of step 1's cleanup.
- The GitHub repo exists (`treetoptremor-cyber/hue-ble-remote`, default branch `main`). Step 8 is a normal commit and push to it, not `git init`.

## Goal

A Flutter app for iPhone and Android that controls Philips Hue **Bluetooth** bulbs directly over BLE, with no Hue Bridge. Scope: find nearby Hue bulbs, connect and pair to one, then control power, brightness, white colour temperature and colour. Nothing else (no scenes, groups, schedules, accounts).

## Decisions already made (do not re-open)

- Platform: **Flutter**, targets android + ios only.
- BLE library: **flutter_blue_plus** (pin `^1.35.0`; let pub resolve the latest 1.x).
- Code lives in this repo, `treetoptremor-cyber/hue-ble-remote`, **not** in the isofit repo.
- Project name `hue_ble_remote`, org `com.hueble`.
- Verified already: Flutter 3.47.5 stable (Dart 3.13.4) installs cleanly on Linux x86_64 from the official tarball, and a fresh `flutter create --org com.hueble --project-name hue_ble_remote --platforms android,ios hue-ble-remote` passes `flutter analyze` and `flutter test`.

## Constraints the executing agent must know

- A cloud container has **no Bluetooth radio**. Nothing can be tested against a real bulb there. Everything that can be verified without hardware must be (analyze, unit tests, builds). Hardware testing is a manual checklist for the user (see "Device checklist").
- iOS cannot be built on Linux. If the agent runs on a Mac with Xcode, do `flutter build ios --no-codesign` as an extra check. Otherwise skip and say so.
- Android debug APK can be built on Linux if the Android SDK command-line tools can be downloaded (dl.google.com). Best effort.

## Hue BLE protocol (reverse-engineered, used by the HueBLE Python library and the Home Assistant hue_ble integration)

| Purpose | UUID | Encoding |
|---|---|---|
| Advertised service (Signify), use to identify Hue bulbs in scan results | `0000fe0f-0000-1000-8000-00805f9b34fb` (16-bit `fe0f`) | — |
| Light control service | `932c32bd-0000-47a2-835a-a8d455b859dd` | — |
| Power | `932c32bd-0002-47a2-835a-a8d455b859dd` | 1 byte: `0x00` off, `0x01` on. read / write / notify |
| Brightness | `932c32bd-0003-47a2-835a-a8d455b859dd` | 1 byte: 1–254. read / write / notify |
| Colour temperature | `932c32bd-0004-47a2-835a-a8d455b859dd` | uint16 little-endian, **mireds**, 153–500 (some bulbs cap at 454). read / write / notify |
| Colour (CIE 1931 xy) | `932c32bd-0005-47a2-835a-a8d455b859dd` | 4 bytes: x as uint16 LE, y as uint16 LE, each `round(value * 0xFFFF)`. read / write / notify |
| Bulb name (optional, less certain) | `97fe6561-0003-4f62-86e9-b71ee2da3d22` | UTF-8 string, read. Wrap in try/catch; fall back to advertised name |
| Model number (standard Device Information 0x180A) | `00002a24-0000-1000-8000-00805f9b34fb` | UTF-8 string |

Notes:
- White-only bulbs have no colour characteristic; White Ambiance has temperature but no colour. Treat temperature and colour characteristics as **optional** and hide UI for what's missing.
- Writing temperature switches the bulb to CT mode; writing xy switches to colour mode. No mode characteristic is needed.
- The control characteristics are **encrypted**: the phone must be bonded with the bulb.
  - Android: call `device.createBond()` right after `connect()` (Android only; guard with `Platform.isAndroid`).
  - iOS: the OS shows the pairing prompt automatically on the first read of an encrypted characteristic. Show a status line telling the user to accept it.
- A bulb already set up in the official Hue Bluetooth app must be **reset from that app** (Settings → the bulb → Reset) before another phone can bond to it. New bulbs accept a bond out of the box. Put this in the README and in the scan page's empty-state hint.

## Colour math (Philips' documented conversion, put in `lib/color_utils.dart`)

RGB (sRGB 0..1) → xy:
1. Linearise each channel: `c > 0.04045 ? ((c + 0.055) / 1.055) ^ 2.4 : c / 12.92`
2. Wide RGB D65 matrix:
   `X = r*0.664511 + g*0.154324 + b*0.162028`
   `Y = r*0.283881 + g*0.668433 + b*0.047685`
   `Z = r*0.000088 + g*0.072310 + b*0.986039`
3. `x = X/(X+Y+Z)`, `y = Y/(X+Y+Z)`; if the sum is 0 return D65 white (0.3127, 0.3290).

xy → RGB (for previewing the bulb's current colour at full brightness):
1. `z = 1 - x - y`, `Y = 1`, `X = (Y / y) * x`, `Z = (Y / y) * z` (guard y <= 0 → white)
2. `r =  X*1.656492 - Y*0.354851 - Z*0.255038`
   `g = -X*0.707196 + Y*1.655397 + Z*0.036152`
   `b =  X*0.051713 - Y*0.121364 + Z*1.011530`
3. Clamp negatives to 0, divide all by the max if the max > 1, then apply gamma: `c <= 0.0031308 ? 12.92*c : 1.055*c^(1/2.4) - 0.055`.

Temperature: `mireds = round(1e6 / kelvin)`, `kelvin = 1e6 / mireds`. UI range 2000 K – 6500 K, i.e. mireds 500 – 154; clamp to 153–500 before writing.

## File layout

```
lib/main.dart          MaterialApp (Material 3, orange seed, light + dark), home = ScanPage
lib/hue_ble.dart       HueUuids, HueLightState, pure encode/decode functions, HueLight class
lib/color_utils.dart   rgbToXy, xyToRgb, kelvinToMireds, miredsToKelvin (pure Dart, no Flutter imports)
lib/scan_page.dart     scan + list Hue bulbs, tap to open LightPage
lib/light_page.dart    connect flow + controls
test/hue_ble_test.dart        encoder/decoder round trips and bounds
test/color_utils_test.dart    colour conversions
README.md
```

`HueLight` API (wrap a `BluetoothDevice`):
- `Future<void> connect({void Function(String status)? onStatus})`: connect (20 s timeout) → createBond on Android → discoverServices → locate the light service and its characteristics (throw a clear StateError if the service is missing) → read current state → `setNotifyValue(true)` on each present characteristic and fold notifications into the state stream (use `device.cancelWhenDisconnected` for the subscriptions; ignore notify failures).
- `Stream<HueLightState> get stateStream`, `HueLightState get state`.
- `bool get supportsTemperature`, `bool get supportsColor`.
- `setPower(bool)`, `setBrightness(int 1..254)`, `setTemperature(int mireds)`, `setColor(double x, double y)`: write with response, then emit the new state.
- `refresh()`, `disconnect()`, `dispose()`.
- `String get name`: bulb name characteristic if readable, else platformName / advName, else "Hue light".

Scan page:
- Listen to `FlutterBluePlus.adapterState`; start a 15 s scan automatically when the adapter is on, with a Scan button to rescan. Show an "turn Bluetooth on" message when it's off.
- Scan **without** a service filter and filter client-side: keep results whose `advertisementData.serviceUuids` contains `Guid('fe0f')` or whose advertised/platform name contains "hue" (case-insensitive). Client-side filtering is more robust across Android radios than a hardware filter.
- List tile: bulb icon, name, remote id and RSSI. Tap → stop scan → push LightPage.
- Empty state text: "Bulb powered on? If it was set up with the Hue Bluetooth app, reset it there first so it accepts a new pairing."

Light page:
- On init call `connect`, showing the status text and a spinner. On error show the message and a Retry button. If `connectionState` goes to disconnected after being ready, show "Disconnected" with Reconnect.
- Controls, in cards: Power switch; Brightness slider (1–254 shown as %); if supported, White temperature slider (2000–6500 K, labelled Warm/Cool); if supported, Colour: a preview circle, a hue slider (0–360) over a rainbow gradient bar, a saturation slider, and ~7 preset swatches. HSV → RGB → xy on write; bulb xy → RGB → HSV to position sliders on load.
- Throttle writes while dragging (at most one write per ~120 ms) and always write the final value in `onChangeEnd`. Don't overwrite slider positions from notifications while the user is dragging.
- Show write errors in a SnackBar. Disconnect in `dispose`.

## Platform configuration

Android (`android/app/src/main/AndroidManifest.xml`):
- First check the plugin's own manifest in the pub cache (`~/.pub-cache/hosted/pub.dev/flutter_blue_plus-*/android/src/main/AndroidManifest.xml`) and its README. Recent versions already declare the Bluetooth permissions and request them at runtime. Add to the app manifest **only what the plugin doesn't already declare**, and if you duplicate anything, use identical attributes so the manifest merger doesn't conflict. The reference set from the flutter_blue_plus README is:
  ```xml
  <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
  <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
  <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
  <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
  ```
- minSdk must be ≥ 21 (Flutter's default `flutter.minSdkVersion` is fine). Confirm nothing in the plugin's build.gradle demands a higher compileSdk than Flutter's default.

iOS (`ios/Runner/Info.plist`): add `NSBluetoothAlwaysUsageDescription` and `NSBluetoothPeripheralUsageDescription` with "Used to find and control your Hue Bluetooth lights." Set `platform :ios, 'X'` in `ios/Podfile` to the minimum the plugin's podspec requires (check `ios/flutter_blue_plus.podspec` in the pub cache).

## Steps, each with its verification

1. Scaffold: `flutter create --org com.hueble --project-name hue_ble_remote --platforms android,ios hue-ble-remote`. Delete the generated counter test.
   → verify: `flutter analyze` = "No issues found", `flutter test` passes (or reports no tests).
2. `flutter pub add flutter_blue_plus`. Read the plugin's Android manifest, README permission section and iOS podspec from the pub cache.
   → verify: `flutter pub get` resolves; write down the plugin's declared permissions and minimum iOS version for step 5.
3. Write `lib/color_utils.dart` and `lib/hue_ble.dart` with the pure functions first, then `HueLight`. Write the two test files.
   → verify: `flutter test` green. Required cases: power encode/decode both values; brightness clamps to 1–254; mireds encodes little-endian (e.g. 370 → `[0x72, 0x01]`) and clamps to 153–500; xy encodes `[x_lo, x_hi, y_lo, y_hi]` and decodes back within 1/65535; xy of pure red ≈ (0.70, 0.30), of white ≈ (0.32, 0.33); xyToRgb(rgbToXy(red)) has r ≈ 1 and g, b < 0.05, same for green and blue; kelvin ↔ mireds round trip.
4. Write `main.dart`, `scan_page.dart`, `light_page.dart`.
   → verify: `flutter analyze` = 0 issues (treat infos as failures too), and `flutter test` still green.
5. Platform config per the section above.
   → verify: `python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('android/app/src/main/AndroidManifest.xml')"` and `python3 -c "import plistlib; plistlib.load(open('ios/Runner/Info.plist','rb'))"` both succeed; grep confirms the two NSBluetooth keys and the BLUETOOTH_SCAN / BLUETOOTH_CONNECT permissions are present exactly once after merging considerations.
6. Android build, best effort: install Android command-line tools, `sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"`, accept licenses, `flutter config --android-sdk`, `flutter doctor`, then `flutter build apk --debug`.
   → verify: `build/app/outputs/flutter-apk/app-debug.apk` exists. If the SDK can't be fetched, say "skipped: Android SDK download blocked" rather than pretending. On a Mac also run `flutter build ios --no-codesign`.
7. README.md: what it does, supported bulbs (Hue bulbs with the Bluetooth logo, 2019 or newer), install Flutter, `flutter pub get`, run on a **physical** phone (simulators/emulators have no BLE), iOS signing note (open `ios/Runner.xcworkspace`, set a team), pairing steps (reset in official app if previously paired → scan → tap → accept pairing prompt), the protocol table above, troubleshooting (bulb not listed → power cycle; pairing fails → reset bulb and forget it in phone Bluetooth settings; "insufficient authentication" → bond not established).
   → verify: every UUID in the README appears verbatim in `lib/hue_ble.dart` (grep each one).
8. Git: commit everything to this repository (Flutter's generated .gitignore is fine) and push to `main`, or to a branch plus pull request if the user prefers. If access is denied, tell the user to grant the Claude GitHub App access to the repo, then retry.
   → verify: `git status` clean and the push succeeded (or the exact blocker reported).

## Final verification pass (report each as PASS / FAIL / SKIPPED with reason)

- [ ] `flutter analyze` → No issues found
- [ ] `flutter test` → all tests passed, list the count
- [ ] `flutter build apk --debug` → APK path, or SKIPPED with reason
- [ ] `flutter build ios --no-codesign` → only on macOS, else SKIPPED
- [ ] AndroidManifest.xml parses; permissions present without merger conflicts
- [ ] Info.plist parses; both NSBluetooth keys present
- [ ] README UUIDs match code
- [ ] Working tree committed; pushed to GitHub or blocker stated

## Device checklist (for the user, cannot be automated)

1. Bulb powered on and, if previously set up in the Hue Bluetooth app, reset from that app.
2. Open the app, Bluetooth on → the bulb appears in the list within ~15 s.
3. Tap it → pairing prompt appears on the phone → accept → controls appear with the bulb's real current state.
4. Power switch toggles the bulb; brightness slider dims live; temperature slider goes warm ↔ cool; colour swatches change colour.
5. Change the bulb from the official Hue app or a switch → the app's controls update (notifications working).
6. Kill and relaunch the app → reconnect works without a new pairing prompt.
