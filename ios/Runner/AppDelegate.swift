import Flutter
import UIKit

/// Hands widget taps to Dart: now if it is listening, else when it asks.
enum WidgetLinks {
  static var channel: FlutterMethodChannel?
  static var pending: String?
  static var dartReady = false

  static func received(_ url: URL) {
    guard url.scheme == "bluelight" else { return }
    let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "id" })?.value
    guard let id, !id.isEmpty else { return }
    if dartReady {
      channel?.invokeMethod("open", arguments: id)
    } else {
      pending = id
    }
  }
}

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
    WidgetLinks.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takePendingOpen":
        WidgetLinks.dartReady = true
        let id = WidgetLinks.pending
        WidgetLinks.pending = nil
        result(id)
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
