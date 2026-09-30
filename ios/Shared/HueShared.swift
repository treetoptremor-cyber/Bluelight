// Shared by the app (Runner) and the widget extension (HueWidgets):
// the light list the Flutter app publishes, a minimal native Bluetooth
// power switch, and the App Intents that widgets and Control Center run.
//
// The intents adopt LiveActivityIntent so the system performs them in the
// app's process (launched in the background if needed), where CoreBluetooth
// works; it is unreliable inside an extension process.

import AppIntents
import CoreBluetooth
import Foundation
import WidgetKit

// MARK: - Shared data

enum HueShared {
  static let appGroup = "group.com.hueble.hueBleRemote"
  static let key = "widgetData"

  /// A light or group as shown in widgets.
  struct Target: Codable, Hashable {
    let id: String
    let name: String
    /// CoreBluetooth peripheral identifiers of its lights.
    let lights: [String]
    var on: Bool
    /// #RRGGBB of its current colour (when on).
    let color: String
    let isGroup: Bool
  }

  struct Snapshot: Codable {
    var targets: [Target]
    /// Every saved light, for "All off".
    var all: [String]
  }

  static var defaults: UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }

  static func load() -> Snapshot {
    guard let data = defaults.data(forKey: key),
      let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    else { return Snapshot(targets: [], all: []) }
    return snap
  }

  static func save(_ snap: Snapshot) {
    if let data = try? JSONEncoder().encode(snap) {
      defaults.set(data, forKey: key)
    }
  }

  /// Saves JSON published by the Flutter app.
  static func saveJSON(_ json: String) {
    guard let data = json.data(using: .utf8),
      (try? JSONDecoder().decode(Snapshot.self, from: data)) != nil
    else { return }
    defaults.set(data, forKey: key)
  }

  /// Records that [lights] were switched, so widgets show it straight away.
  static func markSwitched(_ lights: Set<String>, on: Bool) {
    var snap = load()
    for i in snap.targets.indices where !lights.isDisjoint(with: snap.targets[i].lights) {
      snap.targets[i].on = on
    }
    save(snap)
  }

  static func reloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
    if #available(iOS 18.0, *) {
      ControlCenter.shared.reloadAllControls()
    }
  }
}

// MARK: - Bluetooth

/// Switches Hue Bluetooth bulbs on or off with CoreBluetooth: connect by
/// identifier (the phone is already paired), write the power
/// characteristic, disconnect.
final class HueBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  static let shared = HueBLE()

  private static let lightService = CBUUID(string: "932C32BD-0000-47A2-835A-A8D455B859DD")
  private static let power = CBUUID(string: "932C32BD-0002-47A2-835A-A8D455B859DD")

  private let queue = DispatchQueue(label: "hue.ble")
  private var central: CBCentralManager?
  private var stateWaiters: [(Bool) -> Void] = []
  private var jobs: [UUID: Job] = [:]

  private final class Job {
    let peripheral: CBPeripheral
    let value: Data
    let done: (Bool) -> Void
    var finished = false

    init(peripheral: CBPeripheral, value: Data, done: @escaping (Bool) -> Void) {
      self.peripheral = peripheral
      self.value = value
      self.done = done
    }
  }

  /// Returns how many lights were switched.
  func setPower(_ ids: [String], on: Bool, timeout: TimeInterval = 10) async -> Int {
    let uuids = ids.compactMap(UUID.init(uuidString:))
    guard !uuids.isEmpty else { return 0 }
    return await withCheckedContinuation { cont in
      queue.async {
        self.whenPoweredOn { ready in
          guard ready, let central = self.central else {
            cont.resume(returning: 0)
            return
          }
          let peripherals = central.retrievePeripherals(withIdentifiers: uuids)
          if peripherals.isEmpty {
            cont.resume(returning: 0)
            return
          }
          var remaining = peripherals.count
          var ok = 0
          var resumed = false
          let finish = {
            if !resumed {
              resumed = true
              cont.resume(returning: ok)
            }
          }
          for p in peripherals {
            let job = Job(peripheral: p, value: Data([on ? 1 : 0])) { success in
              if success { ok += 1 }
              remaining -= 1
              if remaining == 0 { finish() }
            }
            self.jobs[p.identifier] = job
            p.delegate = self
            central.connect(p)
          }
          self.queue.asyncAfter(deadline: .now() + timeout) {
            for p in peripherals {
              if let job = self.jobs[p.identifier] { self.end(job, success: false) }
            }
            finish()
          }
        }
      }
    }
  }

  private func whenPoweredOn(_ then: @escaping (Bool) -> Void) {
    if central == nil {
      central = CBCentralManager(delegate: self, queue: queue)
    }
    if central?.state == .poweredOn { return then(true) }
    stateWaiters.append(then)
    queue.asyncAfter(deadline: .now() + 3) {
      let waiters = self.stateWaiters
      self.stateWaiters.removeAll()
      waiters.forEach { $0(self.central?.state == .poweredOn) }
    }
  }

  private func end(_ job: Job, success: Bool) {
    guard !job.finished else { return }
    job.finished = true
    jobs[job.peripheral.identifier] = nil
    central?.cancelPeripheralConnection(job.peripheral)
    job.done(success)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state != .unknown, central.state != .resetting else { return }
    let waiters = stateWaiters
    stateWaiters.removeAll()
    waiters.forEach { $0(central.state == .poweredOn) }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.lightService])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    if let job = jobs[peripheral.identifier] { end(job, success: false) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let job = jobs[peripheral.identifier] else { return }
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.lightService })
    else { return end(job, success: false) }
    peripheral.discoverCharacteristics([Self.power], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let job = jobs[peripheral.identifier] else { return }
    guard let c = service.characteristics?.first(where: { $0.uuid == Self.power })
    else { return end(job, success: false) }
    peripheral.writeValue(job.value, for: c, type: .withResponse)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    if let job = jobs[peripheral.identifier] { end(job, success: error == nil) }
  }
}

// MARK: - App Intents

@available(iOS 17.0, *)
struct TargetEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
  static var defaultQuery = TargetQuery()

  var id: String
  var name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 17.0, *)
struct TargetQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [TargetEntity] {
    HueShared.load().targets
      .filter { identifiers.contains($0.id) }
      .map { TargetEntity(id: $0.id, name: $0.name) }
  }

  func suggestedEntities() async throws -> [TargetEntity] {
    HueShared.load().targets.map { TargetEntity(id: $0.id, name: $0.name) }
  }

  func defaultResult() async -> TargetEntity? {
    try? await suggestedEntities().first
  }
}

/// Switches a light or group on or off.
@available(iOS 17.0, *)
struct SetPowerIntent: SetValueIntent, LiveActivityIntent {
  static var title: LocalizedStringResource = "Switch lights"
  static var description = IntentDescription("Turns a Hue light or group on or off.")

  @Parameter(title: "Lights") var target: TargetEntity
  @Parameter(title: "On") var value: Bool

  init() {}

  init(target: TargetEntity, value: Bool) {
    self.target = target
    self.value = value
  }

  func perform() async throws -> some IntentResult {
    guard let t = HueShared.load().targets.first(where: { $0.id == target.id }) else {
      return .result()
    }
    _ = await HueBLE.shared.setPower(t.lights, on: value)
    HueShared.markSwitched(Set(t.lights), on: value)
    HueShared.reloadWidgets()
    return .result()
  }
}

/// Turns every saved light off.
@available(iOS 17.0, *)
struct AllOffIntent: AppIntent, LiveActivityIntent {
  static var title: LocalizedStringResource = "All lights off"
  static var description = IntentDescription("Turns every Hue light off.")

  func perform() async throws -> some IntentResult {
    let all = HueShared.load().all
    _ = await HueBLE.shared.setPower(all, on: false)
    HueShared.markSwitched(Set(all), on: false)
    HueShared.reloadWidgets()
    return .result()
  }
}
