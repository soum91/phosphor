import Foundation
import AppIntents
import WidgetKit

// MARK: - Entities

struct PresetEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV Preset"
    static var defaultQuery = PresetQuery()

    var id: String
    var name: String
    var icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
    init(id: String, name: String, icon: String) { self.id = id; self.name = name; self.icon = icon }
    init(_ p: TVPreset) { id = p.id; name = p.name; icon = p.icon }
}

struct PresetQuery: EntityStringQuery {
    private func everything() -> [PresetEntity] { PresetStore.load().map(PresetEntity.init) }
    func entities(for identifiers: [String]) async throws -> [PresetEntity] { everything().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [PresetEntity] {
        let q = string.lowercased()
        return everything().filter { $0.name.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [PresetEntity] { everything() }
}

/// An input: the TV's own list once it has been read over Wi-Fi, otherwise the remote's HDMI keys.
struct InputEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV Input"
    static var defaultQuery = InputQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct InputQuery: EntityStringQuery {
    static func everything() -> [InputEntity] {
        let known = InputCache.load()
        if !known.isEmpty { return known.map { InputEntity(id: $0.uri, name: $0.name) } }
        return Keys.builtin.filter { $0.group == .inputs && $0.id != "Input" }.map { InputEntity(id: $0.id, name: $0.label) }
    }
    func entities(for identifiers: [String]) async throws -> [InputEntity] {
        let all = Self.everything()
        return identifiers.map { id in all.first { $0.id == id } ?? InputEntity(id: id, name: Inputs.label(id)) }
    }
    func entities(matching string: String) async throws -> [InputEntity] {
        let q = string.lowercased()
        return Self.everything().filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [InputEntity] { Self.everything() }
}

/// An app installed on the TV.
struct TVAppEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV App"
    static var defaultQuery = TVAppQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TVAppQuery: EntityStringQuery {
    static func everything() -> [TVAppEntity] {
        let known = AppCache.load()
        let side = SideAppStore.load().map { TVAppEntity(id: "side:" + $0.package, name: $0.title) }
        if !known.isEmpty { return known.map { TVAppEntity(id: $0.uri, name: $0.title) } + side }
        return ["Netflix", "YouTube", "Prime Video", "Disney+", "Spotify"].map { TVAppEntity(id: $0, name: $0) } + side
    }
    func entities(for identifiers: [String]) async throws -> [TVAppEntity] {
        let all = Self.everything()
        return identifiers.map { id in all.first { $0.id == id } ?? TVAppEntity(id: id, name: Apps.label(id)) }
    }
    func entities(matching string: String) async throws -> [TVAppEntity] {
        let q = string.lowercased()
        return Self.everything().filter { $0.name.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [TVAppEntity] { Self.everything() }
}

struct ButtonEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV Remote Button"
    static var defaultQuery = ButtonQuery()

    var id: String
    var name: String
    var symbol: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: symbol.map { DisplayRepresentation.Image(systemName: $0) })
    }
    init(_ d: KeyDef) { id = d.id; name = d.label; symbol = d.symbol }
    init(id: String) {
        self.id = id
        name = Keys.label(id)
        symbol = Keys.def(id)?.symbol
    }
}

struct ButtonQuery: EntityStringQuery {
    private func everything() -> [ButtonEntity] { Keys.all().map { ButtonEntity($0) } }
    func entities(for identifiers: [String]) async throws -> [ButtonEntity] { identifiers.map { ButtonEntity(id: $0) } }
    func entities(matching string: String) async throws -> [ButtonEntity] {
        let q = string.lowercased()
        return everything().filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [ButtonEntity] { everything() }
}

/// Anything one tap can do: a button, an app, an input, a preset, power, screen. Used by the one-button
/// widget and the Control Center button.
struct ShortcutEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV Action"
    static var defaultQuery = ShortcutQuery()

    var id: String
    var name: String
    var symbol: String
    var section: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(section)", image: .init(systemName: symbol))
    }
}

enum QuickActions {
    static func all() -> [ShortcutEntity] {
        var out: [ShortcutEntity] = [
            .init(id: "power", name: "TV power", symbol: "power", section: "TV"),
            .init(id: "on", name: "TV on", symbol: "power.circle.fill", section: "TV"),
            .init(id: "off", name: "TV off", symbol: "power.circle", section: "TV"),
            .init(id: "screen", name: "Screen on/off", symbol: "tv.slash", section: "TV"),
            .init(id: "mute", name: "Mute", symbol: "speaker.slash.fill", section: "TV"),
            .init(id: "volUp", name: "Volume up", symbol: "speaker.plus.fill", section: "TV"),
            .init(id: "volDown", name: "Volume down", symbol: "speaker.minus.fill", section: "TV"),
        ]
        out += PresetStore.load().map { ShortcutEntity(id: "preset:" + $0.id, name: $0.name, symbol: $0.icon, section: "Preset") }
        out += TVAppQuery.everything().map { ShortcutEntity(id: "app:" + $0.id, name: $0.name, symbol: Apps.symbol($0.name), section: "App") }
        out += InputQuery.everything().map { ShortcutEntity(id: "input:" + $0.id, name: $0.name, symbol: "rectangle.portrait.and.arrow.forward", section: "Input") }
        out += Keys.all().map { ShortcutEntity(id: "key:" + $0.id, name: $0.label, symbol: $0.symbol ?? "circle.grid.3x3.fill", section: "Button") }
        return out
    }

    static func entity(_ id: String) -> ShortcutEntity {
        if let e = all().first(where: { $0.id == id }) { return e }
        let (kind, rest) = split(id)
        switch kind {
        case "app": return .init(id: id, name: Apps.label(rest), symbol: Apps.symbol(rest), section: "App")
        case "input": return .init(id: id, name: Inputs.label(rest), symbol: "rectangle.portrait.and.arrow.forward", section: "Input")
        case "key": return .init(id: id, name: Keys.label(rest), symbol: Keys.def(rest)?.symbol ?? "circle.grid.3x3.fill", section: "Button")
        default: return .init(id: id, name: "Gone", symbol: "questionmark", section: "")
        }
    }

    private static func split(_ id: String) -> (String, String) {
        guard let i = id.firstIndex(of: ":") else { return (id, "") }
        return (String(id[..<i]), String(id[id.index(after: i)...]))
    }

    static func run(_ id: String) async throws {
        let (kind, rest) = split(id)
        switch kind {
        case "power": try await TV.perform(.power(nil))
        case "on": try await TV.perform(.power(true))
        case "off": try await TV.perform(.power(false))
        case "screen": try await TV.perform(.screen(TVState.stored.screenOff == true))
        case "mute": try await TV.perform(.mute(nil))
        case "volUp": try await TV.perform(.volumeUp(2))
        case "volDown": try await TV.perform(.volumeDown(2))
        case "preset":
            guard let p = PresetStore.load().first(where: { $0.id == rest }) else { throw AppError("That preset doesn't exist anymore.") }
            try await Presets.run(p)
        case "app":
            if TVState.stored.power != true { try await TV.perform(.power(true)); try? await Task.sleep(nanoseconds: 3_000_000_000) }
            try await TV.perform(.app(rest))
        case "input":
            try await TV.perform(.input(rest))
        case "key": try await TV.perform(.key(rest))
        default: throw AppError("Pick an action for this button.")
        }
    }
}

extension Apps {
    static func symbol(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("netflix") { return "n.square.fill" }
        if l.contains("youtube") { return "play.rectangle.fill" }
        if l.contains("spotify") || l.contains("music") { return "music.note" }
        if l.contains("prime") || l.contains("disney") || l.contains("crave") || l.contains("max") || l.contains("plex") { return "film" }
        if l.contains("twitch") || l.contains("game") { return "gamecontroller" }
        if l.contains("browser") || l.contains("chrome") { return "globe" }
        if l.contains("setting") { return "gearshape" }
        return "app.fill"
    }
}

struct ShortcutQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutEntity] { identifiers.map(QuickActions.entity) }
    func entities(matching string: String) async throws -> [ShortcutEntity] {
        let q = string.lowercased()
        return QuickActions.all().filter { $0.name.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [ShortcutEntity] { QuickActions.all() }
}

// MARK: - Intents

private func reload() { WidgetCenter.shared.reloadAllTimelines() }

struct TVPowerIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set TV Power"
    static var description = IntentDescription("Turns the Sony TV on or off, over Wi-Fi or through the IR blaster.")

    @Parameter(title: "On")
    var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    static var parameterSummary: some ParameterSummary { Summary("Turn the TV \(\.$on)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.power(on))
        reload()
        if !on { Donate.off() }
        return .result(dialog: IntentDialog(stringLiteral: on ? "TV on." : "TV off."))
    }
}

struct TVOffIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Turn TV Off"
    static var description = IntentDescription("Turns the Sony TV off.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.power(false))
        reload()
        Donate.off()
        return .result(dialog: "TV off.")
    }
}

struct TVOnIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Turn TV On"
    static var description = IntentDescription("Turns the Sony TV on.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.power(true))
        reload()
        return .result(dialog: "TV on.")
    }
}

struct ToggleTVIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Toggle TV Power"
    static var description = IntentDescription("Turns the TV on if it's off, off if it's on.")
    func perform() async throws -> some IntentResult {
        let s = TVState.stored
        // Known state: send the exact command, which works over IR as well.
        if let p = s.power, Date().timeIntervalSince(s.updated) < 300 {
            try await TV.perform(.power(!p))
        } else {
            try await TV.perform(.power(nil))
        }
        reload()
        return .result()
    }
}

struct VolumeUpIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "TV Volume Up"
    static var description = IntentDescription("Turns the TV up by a few steps.")

    @Parameter(title: "Steps", default: 2, inclusiveRange: (1, 20))
    var steps: Int

    init() {}
    init(steps: Int) { self.steps = steps }

    static var parameterSummary: some ParameterSummary { Summary("Turn the TV up \(\.$steps) steps") }

    func perform() async throws -> some IntentResult {
        try await TV.perform(.volumeUp(steps))
        reload()
        return .result()
    }
}

struct VolumeDownIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "TV Volume Down"
    static var description = IntentDescription("Turns the TV down by a few steps.")

    @Parameter(title: "Steps", default: 2, inclusiveRange: (1, 20))
    var steps: Int

    init() {}
    init(steps: Int) { self.steps = steps }

    static var parameterSummary: some ParameterSummary { Summary("Turn the TV down \(\.$steps) steps") }

    func perform() async throws -> some IntentResult {
        try await TV.perform(.volumeDown(steps))
        reload()
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set TV Volume"
    static var description = IntentDescription("Sets the TV to an exact volume (needs the TV on Wi-Fi).")

    @Parameter(title: "Volume", default: 15, inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary { Summary("Set the TV volume to \(\.$level)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.setVolume(level))
        reload()
        return .result(dialog: "Volume \(level).")
    }
}

struct MuteIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Mute TV"
    static var description = IntentDescription("Mutes or unmutes the TV.")
    func perform() async throws -> some IntentResult {
        try await TV.perform(.mute(nil))
        reload()
        return .result()
    }
}

struct SetInputIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set TV Input"
    static var description = IntentDescription("Switches the TV to an HDMI input.")

    @Parameter(title: "Input")
    var input: InputEntity

    init() {}
    init(input: InputEntity) { self.input = input }

    static var parameterSummary: some ParameterSummary { Summary("Switch the TV to \(\.$input)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.input(input.id))
        reload()
        return .result(dialog: "\(input.name).")
    }
}

struct LaunchAppIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Open TV App"
    static var description = IntentDescription("Opens an app on the TV (Netflix, YouTube…), turning the TV on first if needed.")

    @Parameter(title: "App")
    var app: TVAppEntity

    init() {}
    init(app: TVAppEntity) { self.app = app }

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$app) on the TV") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await QuickActions.run("app:" + app.id)
        reload()
        return .result(dialog: "\(app.name).")
    }
}

struct RunPresetIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Run TV Preset"
    static var description = IntentDescription("Runs one of your Obsidian presets.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    init() {}
    init(preset: PresetEntity) { self.preset = preset }

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$preset)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let p = PresetStore.load().first(where: { $0.id == preset.id }) else {
            throw AppError("That preset doesn't exist anymore.")
        }
        try await Presets.run(p)
        reload()
        Donate.preset(p)
        return .result(dialog: "\(p.name).")
    }
}

struct PressButtonIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Press TV Button"
    static var description = IntentDescription("Presses any button on the Bravia remote: Home, Back, the d-pad, play, pause, inputs and more.")

    @Parameter(title: "Button")
    var button: ButtonEntity

    @Parameter(title: "Times", default: 1, inclusiveRange: (1, 20))
    var times: Int

    init() {}
    init(button: ButtonEntity) { self.button = button; self.times = 1 }
    init(key: String) { self.button = ButtonEntity(id: key); self.times = 1 }

    static var parameterSummary: some ParameterSummary { Summary("Press \(\.$button) \(\.$times) times") }

    func perform() async throws -> some IntentResult {
        for i in 0..<max(1, times) {
            try await TV.perform(.key(button.id))
            if i < times - 1 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        reload()
        return .result()
    }
}

struct ScreenIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set TV Screen"
    static var description = IntentDescription("Turns the picture off while the TV keeps playing (great for music), or back on.")

    @Parameter(title: "Screen on")
    var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    static var parameterSummary: some ParameterSummary { Summary("Turn the TV screen \(\.$on)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TV.perform(.screen(on))
        reload()
        return .result(dialog: IntentDialog(stringLiteral: on ? "Screen on." : "Screen off."))
    }
}

struct ToggleScreenIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Toggle TV Screen"
    static var description = IntentDescription("Turns the picture off, or back on, without stopping what's playing.")
    func perform() async throws -> some IntentResult {
        try await TV.perform(.screen(TVState.stored.screenOff == true))
        reload()
        return .result()
    }
}

struct TypeTextIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Type on TV"
    static var description = IntentDescription("Types text into the search or text box that's open on the TV.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Type \(\.$text) on the TV") }

    func perform() async throws -> some IntentResult {
        try await TV.perform(.text(text))
        return .result()
    }
}

struct GetTVPowerIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Is the TV On"
    static var description = IntentDescription("Asks the TV over Wi-Fi whether it's on. Returns true or false.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard TVConfig.stored.hasWiFi else { throw AppError("Add the TV's Wi-Fi address in Obsidian first.") }
        let s = await TV.refresh()
        reload()
        return .result(value: s.power ?? false)
    }
}

/// One tap, anything: used by the one-button widget.
struct DoActionIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Do TV Action"
    static var description = IntentDescription("Runs a button, app, input, preset or power action on the TV.")

    @Parameter(title: "Action")
    var action: ShortcutEntity?

    init() {}
    init(action: ShortcutEntity?) { self.action = action }

    static var parameterSummary: some ParameterSummary { Summary("Do \(\.$action) on the TV") }

    func perform() async throws -> some IntentResult {
        guard let id = action?.id else { throw AppError("Pick an action for this button.") }
        try await QuickActions.run(id)
        reload()
        return .result()
    }
}

struct RefreshTVIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh TV"
    static var isDiscoverable: Bool = false
    func perform() async throws -> some IntentResult {
        await TV.refresh()
        reload()
        return .result()
    }
}

// MARK: - Widget and Control Center configuration

struct ButtonWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "TV Button"
    static var description = IntentDescription("Pick what the button does.")

    @Parameter(title: "Action")
    var action: ShortcutEntity?

    init() {}
}

@available(iOS 18.0, *)
struct TVPowerSwitchIntent: SetValueIntent {
    static var title: LocalizedStringResource = "TV Power"
    static var isDiscoverable: Bool = false

    @Parameter(title: "On")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await TV.perform(.power(value))
        return .result()
    }
}

@available(iOS 18.0, *)
struct TVMuteSwitchIntent: SetValueIntent {
    static var title: LocalizedStringResource = "TV Mute"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Muted")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await TV.perform(.mute(value))
        return .result()
    }
}

@available(iOS 18.0, *)
struct TVScreenSwitchIntent: SetValueIntent {
    static var title: LocalizedStringResource = "TV Screen"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Screen on")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await TV.perform(.screen(value))
        return .result()
    }
}

@available(iOS 18.0, *)
struct ActionControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Action"

    @Parameter(title: "Action")
    var action: ShortcutEntity?

    init() {}
}

// MARK: - Learning

/// Tells Siri when you switch the TV off or run presets, so it can suggest them at your usual times.
enum Donate {
    static func off() {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: TVOffIntent()) }
    }
    static func preset(_ p: TVPreset) {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: RunPresetIntent(preset: PresetEntity(p))) }
    }
}
