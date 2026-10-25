import WidgetKit
import SwiftUI
import AppIntents

@main
struct PhosphorWidgets: WidgetBundle {
    var body: some Widget {
        TVHomeControl()

        TVWidget()
        ButtonWidget()
        TVPowerControl()
        TVMuteControl()
        TVScreenControl()
        VolumeUpControl()
        VolumeDownControl()
        ActionControl()
    }
}

private let accent = Color(red: 0.72, green: 0.52, blue: 1.0)

// MARK: - Timeline

struct TVEntry: TimelineEntry {
    let date: Date
    let state: TVState
    let name: String
    let setUp: Bool
    let shared: Bool
    let presets: [TVPreset]

    var isOn: Bool { state.power == true }

    static func make() -> TVEntry {
        let cfg = TVConfig.stored
        return TVEntry(date: .now, state: .stored, name: cfg.name, setUp: cfg.hasWiFi || BlasterConfig.stored.isReady,
                       shared: AppGroup.isShared, presets: PresetStore.load())
    }

    static let preview = TVEntry(date: .now, state: TVState(power: true, volume: 18, maxVolume: 100, muted: false, input: "HDMI 2"),
                                 name: "Bravia", setUp: true, shared: true, presets: TVPreset.defaults)
}

struct TVProvider: TimelineProvider {
    func placeholder(in context: Context) -> TVEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (TVEntry) -> Void) {
        let e = TVEntry.make()
        completion(context.isPreview && !e.setUp ? .preview : e)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TVEntry>) -> Void) {
        Task {
            await TV.refresh()
            completion(Timeline(entries: [.make()], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - TV widget

struct TVWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PhosphorTV", provider: TVProvider()) { entry in
            TVWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBG(on: entry.isOn) }
        }
        .configurationDisplayName("TV")
        .description("Power, volume, presets, and a full remote in the large size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

extension WidgetFamily {
    var isAccessory: Bool { self == .accessoryCircular || self == .accessoryRectangular || self == .accessoryInline }
}

struct WidgetBG: View {
    let on: Bool
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family.isAccessory {
            Color.clear
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.03, green: 0.01, blue: 0.05), Color.black],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(on ? 0.32 : 0.06), .clear], center: .topLeading, startRadius: 5, endRadius: 260)
            }
        }
    }
}

struct TVWidgetView: View {
    let entry: TVEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.setUp {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "tv").font(.title2)
                Spacer()
                Text(entry.shared ? "Open Obsidian to set up the TV." : "Widget can't see Obsidian's data. Reinstall with app extensions kept.")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            switch family {
            case .systemMedium: medium
            case .systemLarge: large
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline:
                Label(entry.isOn ? "TV \(entry.state.volume.map { "vol \($0)" } ?? "on")" : "TV off", systemImage: "tv.fill")
            default: small
            }
        }
    }

    private var statusLine: String {
        guard entry.isOn else { return entry.state.power == false ? "Standby" : "Tap to toggle" }
        if entry.state.screenOff == true { return "Screen off" }
        return entry.state.muted == true ? "Muted" : (entry.state.input ?? "On")
    }

    private func roundKey(_ symbol: String, _ intent: some AppIntent, filled: Bool = false, size: CGFloat = 36) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .frame(width: size, height: size)
                .background(filled ? accent : Color.white.opacity(0.12), in: Circle())
                .foregroundStyle(filled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private func press(_ id: String, size: CGFloat = 36) -> some View {
        roundKey(Keys.def(id)?.symbol ?? "circle", PressButtonIntent(key: id), size: size)
    }

    private var volumeText: String { entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "On") : "Off" }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(volumeText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                    Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                roundKey("power", ToggleTVIntent(), filled: entry.isOn, size: 34)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                roundKey("minus", VolumeDownIntent(steps: 2))
                roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent())
                roundKey("plus", VolumeUpIntent(steps: 2))
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(volumeText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    roundKey("power", ToggleTVIntent(), filled: entry.isOn)
                    roundKey("minus", VolumeDownIntent(steps: 2))
                    roundKey("plus", VolumeUpIntent(steps: 2))
                    roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent())
                }
            }
            VStack(spacing: 6) {
                ForEach(entry.presets.prefix(4)) { p in
                    Button(intent: RunPresetIntent(preset: PresetEntity(p))) {
                        Label(p.name, systemImage: p.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 118)
        }
    }

    /// A remote: power, d-pad, back/home, volume, mute, transport and presets.
    private var large: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer()
                roundKey(entry.state.screenOff == true ? "tv" : "tv.slash", ToggleScreenIntent(), filled: entry.state.screenOff == true, size: 34)
                roundKey("power", ToggleTVIntent(), filled: entry.isOn, size: 40)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 0) {
                    Button(intent: VolumeUpIntent(steps: 2)) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 50, height: 40)
                    }.buttonStyle(.plain)
                    Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "VOL") : "VOL")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                    Button(intent: VolumeDownIntent(steps: 2)) {
                        Image(systemName: "minus").font(.system(size: 16, weight: .bold)).frame(width: 50, height: 40)
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.1), in: Capsule())
                Spacer(minLength: 0)
                // D-pad
                VStack(spacing: 2) {
                    press("Up", size: 34)
                    HStack(spacing: 2) {
                        press("Left", size: 34)
                        Button(intent: PressButtonIntent(key: "Confirm")) {
                            Text("OK").font(.system(size: 13, weight: .bold, design: .rounded))
                                .frame(width: 44, height: 44)
                                .background(accent, in: Circle())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        press("Right", size: 34)
                    }
                    press("Down", size: 34)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    press("Return", size: 36)
                    press("Home", size: 36)
                    roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent(), size: 36)
                }
            }
            HStack {
                press("Rewind", size: 34)
                Spacer()
                press("Play", size: 34)
                Spacer()
                press("Pause", size: 34)
                Spacer()
                press("Forward", size: 34)
                Spacer()
                press("Input", size: 34)
            }
            HStack(spacing: 6) {
                ForEach(entry.presets.prefix(3)) { p in
                    Button(intent: RunPresetIntent(preset: PresetEntity(p))) {
                        Label(p.name, systemImage: p.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var circular: some View {
        Button(intent: ToggleTVIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.isOn ? "tv.fill" : "tv").font(.system(size: 16, weight: .semibold))
                    Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "on") : "off").font(.system(size: 12, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(entry.isOn ? "Volume \(entry.state.volume.map { "\($0)" } ?? "–")" : "TV off", systemImage: "tv.fill")
                .font(.headline)
            Text(statusLine).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One-button widget

struct ButtonEntry: TimelineEntry {
    let date: Date
    let action: ShortcutEntity?
    let isOn: Bool
}

struct ButtonProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ButtonEntry {
        ButtonEntry(date: .now, action: ShortcutEntity(id: "power", name: "TV power", symbol: "power", section: "TV"), isOn: true)
    }

    func snapshot(for configuration: ButtonWidgetConfig, in context: Context) async -> ButtonEntry {
        ButtonEntry(date: .now, action: configuration.action ?? placeholder(in: context).action, isOn: TVState.stored.power == true)
    }

    func timeline(for configuration: ButtonWidgetConfig, in context: Context) async -> Timeline<ButtonEntry> {
        let action = configuration.action.map { QuickActions.entity($0.id) }
        return Timeline(entries: [ButtonEntry(date: .now, action: action, isOn: TVState.stored.power == true)],
                        policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

struct ButtonWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PhosphorButton", intent: ButtonWidgetConfig.self, provider: ButtonProvider()) { entry in
            ButtonWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBG(on: entry.isOn && entry.action?.id == "power") }
        }
        .configurationDisplayName("TV button")
        .description("One tap: any remote button, app, input, preset, power or screen off. Long-press the widget › Edit to pick.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct ButtonWidgetView: View {
    let entry: ButtonEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let a = entry.action {
            Button(intent: DoActionIntent(action: a)) {
                if family == .accessoryCircular {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: a.symbol).font(.system(size: 22, weight: .semibold))
                    }
                } else if family == .accessoryRectangular {
                    Label(a.name, systemImage: a.symbol).font(.headline).lineLimit(2)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: a.symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .frame(width: 78, height: 78)
                            .background(accent, in: Circle())
                            .foregroundStyle(.black)
                            .shadow(color: accent.opacity(0.5), radius: 12)
                        Text(a.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.tap").font(.title2)
                if family != .accessoryCircular {
                    Text("Long-press › Edit Widget to pick what this does.").font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - Control Center

@available(iOS 18.0, *)
struct TVPowerProvider: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool {
        if TVConfig.stored.hasWiFi { return await TV.refresh().power ?? false }
        return TVState.stored.power ?? false
    }
}

@available(iOS 18.0, *)
struct TVPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.power", provider: TVPowerProvider()) { on in
            ControlWidgetToggle("TV", isOn: on, action: TVPowerSwitchIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "tv.fill" : "tv")
            }
            .tint(.purple)
        }
        .displayName("TV power")
        .description("Turn the Sony TV on and off.")
    }
}

@available(iOS 18.0, *)
struct TVMuteProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { TVState.stored.muted ?? false }
}

@available(iOS 18.0, *)
struct TVMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.mute", provider: TVMuteProvider()) { muted in
            ControlWidgetToggle("Mute TV", isOn: muted, action: TVMuteSwitchIntent()) { isMuted in
                Label(isMuted ? "Muted" : "Sound on", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .tint(.red)
        }
        .displayName("TV mute")
        .description("Mute and unmute the TV.")
    }
}

@available(iOS 18.0, *)
struct TVScreenProvider: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool { TVState.stored.screenOff != true }
}

@available(iOS 18.0, *)
struct TVScreenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.screen", provider: TVScreenProvider()) { on in
            ControlWidgetToggle("TV screen", isOn: on, action: TVScreenSwitchIntent()) { isOn in
                Label(isOn ? "Screen on" : "Screen off", systemImage: isOn ? "tv" : "tv.slash")
            }
            .tint(.purple)
        }
        .displayName("TV screen")
        .description("Picture off while it keeps playing, or back on.")
    }
}

@available(iOS 18.0, *)
struct VolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.volup") {
            ControlWidgetButton(action: VolumeUpIntent(steps: 2)) {
                Label("TV volume up", systemImage: "speaker.plus.fill")
            }
            .tint(.purple)
        }
        .displayName("TV volume up")
        .description("Two steps louder.")
    }
}

@available(iOS 18.0, *)
struct VolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.voldown") {
            ControlWidgetButton(action: VolumeDownIntent(steps: 2)) {
                Label("TV volume down", systemImage: "speaker.minus.fill")
            }
            .tint(.purple)
        }
        .displayName("TV volume down")
        .description("Two steps quieter.")
    }
}

struct ActionControlValue {
    var name: String
    var symbol: String
    var entity: ShortcutEntity?
}

@available(iOS 18.0, *)
struct ActionControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: ActionControlConfig) -> ActionControlValue {
        ActionControlValue(name: configuration.action?.name ?? "TV button", symbol: configuration.action?.symbol ?? "av.remote.fill",
                           entity: configuration.action)
    }

    func currentValue(configuration: ActionControlConfig) async throws -> ActionControlValue {
        guard let a = configuration.action else { return ActionControlValue(name: "Pick an action", symbol: "av.remote.fill", entity: nil) }
        let e = QuickActions.entity(a.id)
        return ActionControlValue(name: e.name, symbol: e.symbol, entity: e)
    }
}

@available(iOS 18.0, *)
struct ActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.phosphor.action", provider: ActionControlProvider()) { value in
            ControlWidgetButton(action: DoActionIntent(action: value.entity)) {
                Label(value.name, systemImage: value.symbol)
            }
            .tint(.purple)
        }
        .displayName("TV button")
        .description("Any remote button, app, input, preset or power action.")
    }
}
