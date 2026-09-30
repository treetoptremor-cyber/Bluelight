import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Widgets and Control Center read the light list the app publishes.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HueWidgetsBridge")
    let channel = FlutterMethodChannel(
      name: "hue_ble_remote/widgets", binaryMessenger: registrar!.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "publish":
        if let json = call.arguments as? String {
          HueShared.saveJSON(json)
          HueShared.reloadWidgets()
        }
        result(nil)
      case "beginBackgroundTask":
        // Lets the app finish syncing routines to the bulbs after the user
        // locks the phone (iOS allows ~30 s).
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "hue-sync") {
          UIApplication.shared.endBackgroundTask(id)
        }
        result(id.rawValue)
      case "endBackgroundTask":
        if let raw = call.arguments as? Int {
          UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
