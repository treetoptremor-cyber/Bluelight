// Home Screen widgets and Control Center controls for Bluelight.
// Tapping runs an intent from HueShared.swift in the app's process.

import AppIntents
import SwiftUI
import WidgetKit

@main
struct HueWidgetsBundle: WidgetBundle {
  var body: some Widget {
    LightsWidget()
    LightControl()
    AllOffControl()
    AllOnControl()
  }
}

// MARK: - Home Screen widget

struct LightsEntry: TimelineEntry {
  let date: Date
  let targets: [HueShared.Target]
}

struct LightsProvider: TimelineProvider {
  func placeholder(in context: Context) -> LightsEntry {
    LightsEntry(
      date: .now,
      targets: [
        .init(id: "a", name: "Living room", lights: [], on: true, color: "#FFB46B", isGroup: true),
        .init(id: "b", name: "Kitchen", lights: [], on: false, color: "#FFFFFF", isGroup: true),
      ])
  }

  func getSnapshot(in context: Context, completion: @escaping (LightsEntry) -> Void) {
    let targets = HueShared.load().targets
    completion(targets.isEmpty ? placeholder(in: context) : LightsEntry(date: .now, targets: targets))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LightsEntry>) -> Void) {
    // The app and the intents reload the widget whenever something changes.
    completion(Timeline(entries: [LightsEntry(date: .now, targets: HueShared.load().targets)], policy: .never))
  }
}

struct LightsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "LightsWidget", provider: LightsProvider()) { entry in
      LightsWidgetView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Bluelight")
    .description("Switch your favourite lights and groups.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct LightsWidgetView: View {
  let entry: LightsEntry
  @Environment(\.widgetFamily) private var family

  private var capacity: Int {
    switch family {
    case .systemSmall: return 2
    case .systemMedium: return 4
    default: return 8
    }
  }

  var body: some View {
    let targets = Array(entry.targets.prefix(capacity))
    if targets.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "lightbulb").font(.title2)
        Text("Open Bluelight to add lights").font(.caption).multilineTextAlignment(.center)
      }
    } else {
      VStack(spacing: 8) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: family == .systemSmall ? 1 : 2),
          spacing: 8
        ) {
          ForEach(targets, id: \.id) { t in
            Button(intent: SetPowerIntent(target: TargetEntity(id: t.id, name: t.name), value: !t.on)) {
              TargetTile(target: t)
            }
            .buttonStyle(.plain)
          }
        }
        if family != .systemSmall {
          HStack(spacing: 8) {
            Button(intent: AllOnIntent()) {
              Label("All on", systemImage: "lightbulb.fill")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(intent: AllOffIntent()) {
              Label("All off", systemImage: "power")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

struct TargetTile: View {
  let target: HueShared.Target

  var body: some View {
    let color = Color(hex: target.color)
    HStack(spacing: 8) {
      Circle()
        .fill(target.on ? color : Color.gray.opacity(0.25))
        .frame(width: 14, height: 14)
        .shadow(color: target.on ? color.opacity(0.8) : .clear, radius: 4)
      Text(target.name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
      Image(systemName: target.on ? "lightbulb.fill" : "lightbulb")
        .font(.caption)
        .foregroundStyle(target.on ? .primary : .secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(target.on ? color.opacity(0.28) : Color.gray.opacity(0.12))
    )
  }
}

extension Color {
  init(hex: String) {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    self.init(
      red: Double((v >> 16) & 0xFF) / 255,
      green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255)
  }
}

// MARK: - Control Center

struct SelectTargetIntent: ControlConfigurationIntent {
  static var title: LocalizedStringResource = "Choose lights"
  @Parameter(title: "Lights") var target: TargetEntity?
}

struct LightControlValue {
  let entity: TargetEntity?
  let isOn: Bool
}

struct LightControlProvider: AppIntentControlValueProvider {
  func previewValue(configuration: SelectTargetIntent) -> LightControlValue {
    LightControlValue(entity: configuration.target, isOn: false)
  }

  func currentValue(configuration: SelectTargetIntent) async throws -> LightControlValue {
    let on = HueShared.load().targets.first { $0.id == configuration.target?.id }?.on ?? false
    return LightControlValue(entity: configuration.target, isOn: on)
  }
}

struct LightControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    AppIntentControlConfiguration(kind: "LightControl", provider: LightControlProvider()) { value in
      ControlWidgetToggle(
        value.entity?.name ?? "Choose lights",
        isOn: value.isOn,
        action: SetPowerIntent(
          target: value.entity ?? TargetEntity(id: "", name: ""), value: !value.isOn)
      ) { isOn in
        Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
      }
      .tint(.orange)
    }
    .displayName("Hue light")
    .description("Switch a Hue light or group.")
  }
}

struct AllOffControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "AllOffControl") {
      ControlWidgetButton(action: AllOffIntent()) {
        Label("All lights off", systemImage: "power")
      }
    }
    .displayName("All lights off")
    .description("Turns every Hue light off.")
  }
}

struct AllOnControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "AllOnControl") {
      ControlWidgetButton(action: AllOnIntent()) {
        Label("All lights on", systemImage: "lightbulb.fill")
      }
    }
    .displayName("All lights on")
    .description("Turns every Hue light on.")
  }
}
