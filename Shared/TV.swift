import Foundation
import WidgetKit

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// How commands reach the TV.
enum TVRoute: String, Codable, CaseIterable, Identifiable {
    /// Wi-Fi (Sony IP control) first, IR through the blaster when the TV doesn't answer.
    case auto
    case wifi
    case ir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Wi-Fi, then IR"
        case .wifi: return "Wi-Fi only"
        case .ir: return "IR only"
        }
    }
}

struct TVConfig: Codable, Equatable {
    var host: String = ""
    var psk: String = ""
    var name: String = "Sony TV"
    var model: String?
    var mac: String?
    var route: TVRoute = .auto

    var hasWiFi: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    static var stored: TVConfig {
        get { AppGroup.read(TVConfig.self, "tv.json") ?? TVConfig() }
        set { AppGroup.write(newValue, "tv.json") }
    }
}

/// Last known state, for the widget and for deciding what an IR toggle will do.
struct TVState: Codable, Equatable {
    var power: Bool?
    var volume: Int?
    var maxVolume: Int?
    var muted: Bool?
    /// What's on: an input or channel name, or "Apps" when an app is in front.
    var input: String?
    var inputURI: String?
    var screenOff: Bool?
    var via: String?
    var updated: Date = .distantPast

    static var stored: TVState {
        get { AppGroup.read(TVState.self, "state.json") ?? TVState() }
        set { AppGroup.write(newValue, "state.json") }
    }
}

enum InputCache {
    static func load() -> [BraviaInput] { AppGroup.read([BraviaInput].self, "inputs.json") ?? [] }
    static func save(_ l: [BraviaInput]) { AppGroup.write(l, "inputs.json") }
}

enum AppCache {
    static func load() -> [BraviaApp] { AppGroup.read([BraviaApp].self, "apps.json") ?? [] }
    static func save(_ l: [BraviaApp]) { AppGroup.write(l, "apps.json") }
}

enum TVAction: Equatable {
    case power(Bool?)          // nil toggles
    case volumeUp(Int)
    case volumeDown(Int)
    case setVolume(Int)
    case mute(Bool?)           // nil toggles
    case input(String)         // an input URI ("extInput:hdmi?port=2"), a key ("Hdmi2") or an input name
    case app(String)           // an app URI or its title
    case key(String)           // a remote button by Sony's name ("Home", "Confirm")
    case screen(Bool)          // false = picture off, keeps playing
    case text(String)

    var label: String {
        switch self {
        case .power(let on): return on == nil ? "Power" : (on! ? "Power on" : "Power off")
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .setVolume(let v): return "Volume \(v)"
        case .mute: return "Mute"
        case .input(let n): return Inputs.label(n)
        case .app(let a): return Apps.label(a)
        case .key(let k): return Keys.label(k)
        case .screen(let on): return on ? "Screen on" : "Screen off"
        case .text: return "Typing"
        }
    }
}

enum TVPath: String { case wifi = "Wi-Fi", ir = "IR" }

enum Inputs {
    static func find(_ id: String, in list: [BraviaInput] = InputCache.load()) -> BraviaInput? {
        let l = id.lowercased()
        return list.first { $0.uri == id } ?? list.first { $0.key?.lowercased() == l }
            ?? list.first { $0.name.lowercased() == l || $0.title.lowercased() == l }
    }

    static func label(_ id: String) -> String {
        if let i = find(id) { return i.name }
        if let d = Keys.def(id), d.group == .inputs { return d.label }
        return id
    }

    /// The remote key that picks this input, for IR.
    static func key(_ id: String) -> String? {
        if let d = Keys.def(id), d.group == .inputs { return d.id }
        if let k = find(id)?.key { return k }
        if id.lowercased().hasPrefix("extinput:hdmi"), let port = URLComponents(string: id)?.queryItems?.first(where: { $0.name == "port" })?.value {
            return "Hdmi\(port)"
        }
        return nil
    }
}

enum Apps {
    static func find(_ id: String, in list: [BraviaApp] = AppCache.load()) -> BraviaApp? {
        let l = id.lowercased()
        return list.first { $0.uri == id } ?? list.first { $0.title.lowercased() == l }
            ?? list.first { $0.title.lowercased().contains(l) }
    }

    static func label(_ id: String) -> String { find(id)?.title ?? id }

    /// Netflix and YouTube have their own remote buttons.
    static func key(_ id: String) -> String? {
        let l = (find(id)?.title ?? id).lowercased()
        if l.contains("netflix") { return "Netflix" }
        if l.contains("youtube") && !l.contains("music") && !l.contains("kids") { return "YouTube" }
        if l.contains("google play") || l.contains("play store") { return "GooglePlay" }
        return nil
    }
}

/// The one place commands go through, from the app, the widgets, Control Center and Siri.
enum TV {
    @discardableResult
    static func perform(_ action: TVAction, cfg: TVConfig = .stored) async throws -> TVPath {
        var wifiError: Error?
        // Waking from standby: don't sit on a TV whose network is asleep, the blaster can do it.
        let timeout: Double = action == .power(true) ? 2.5 : 4
        if cfg.route != .ir, let b = Bravia(cfg, timeout: timeout) {
            do {
                try await wifi(action, b)
                note(action, .wifi)
                return .wifi
            } catch {
                wifiError = error
                if cfg.route == .wifi { throw error }
            }
        }
        if cfg.route != .wifi, BlasterConfig.stored.isReady, let keys = irKeys(for: action) {
            let learned = LearnedCodes.load(), remote = RemoteCodes.load()
            for (i, k) in keys.enumerated() {
                guard let code = Keys.ir(k, learned: learned, remote: remote) else {
                    throw AppError("No IR code for \(Keys.label(k)) yet. Learn it in Phosphor › Remote.")
                }
                try await IRSender.shared.send(code)
                if i < keys.count - 1 { try? await Task.sleep(nanoseconds: 160_000_000) }
            }
            note(action, .ir)
            return .ir
        }
        if let wifiError { throw wifiError }
        if !cfg.hasWiFi && !BlasterConfig.stored.isReady {
            throw AppError("Set up the TV in Phosphor first.")
        }
        throw AppError("\(action.label) needs \(cfg.hasWiFi ? "the IR blaster" : "the TV on Wi-Fi").")
    }

    private static func isUnsupported(_ e: Error) -> Bool {
        guard let b = e as? BraviaError else { return false }
        return !b.unreachable && !b.auth
    }

    private static func wifi(_ a: TVAction, _ b: Bravia) async throws {
        switch a {
        case .power(let on):
            if let on {
                try await b.setPower(on)
            } else {
                try await b.setPower(!(try await b.power()))
            }
        case .volumeUp(let n), .volumeDown(let n):
            let up: Bool = { if case .volumeUp = a { return true } else { return false } }()
            let steps = max(1, n)
            do {
                try await b.setVolume((up ? "+" : "-") + "\(steps)")
            } catch where isUnsupported(error) {
                // Sound going out to a receiver/sound bar: the remote's volume key still works (HDMI-CEC).
                for _ in 0..<min(steps, 30) { try await press(up ? "VolumeUp" : "VolumeDown", b) }
            }
        case .setVolume(let v):
            try await b.setVolume("\(max(0, v))")
        case .mute(let on):
            do {
                let target: Bool
                if let on { target = on } else { target = !(try await b.volume().muted) }
                try await b.setMute(target)
            } catch where isUnsupported(error) && on == nil {
                try await press("Mute", b)
            }
        case .input(let id):
            if id.lowercased().hasPrefix("extinput:") || id.contains("://") {
                try await b.setContent(id)
            } else if let i = Inputs.find(id) {
                try await b.setContent(i.uri)
            } else if let list = try? await b.inputs(), let i = Inputs.find(id, in: list) {
                InputCache.save(list)
                try await b.setContent(i.uri)
            } else if let k = Inputs.key(id) {
                try await press(k, b)
            } else {
                throw AppError("This TV has no input called \(id).")
            }
        case .app(let id):
            if let app = Apps.find(id) {
                try await b.launch(app.uri)
            } else {
                let list = try await b.apps()
                if !list.isEmpty { AppCache.save(list) }
                guard let app = Apps.find(id, in: list) else { throw AppError("No app called \(id) on the TV.") }
                try await b.launch(app.uri)
            }
        case .key(let k):
            switch k {
            case "WakeUp": try await b.setPower(true)
            case "PowerOff": try await b.setPower(false)
            case "TvPower": try await b.setPower(!(try await b.power()))
            default: try await press(k, b)
            }
        case .screen(let on):
            try await b.setScreenOff(!on)
        case .text(let t):
            try await b.type(t)
        }
    }

    private static func press(_ k: String, _ b: Bravia) async throws {
        guard let code = Keys.ircc(k) else { throw AppError("The TV has no \(Keys.label(k)) button.") }
        try await b.ircc(code)
    }

    /// Which remote buttons do the same thing. Nil when IR can't.
    static func irKeys(for a: TVAction) -> [String]? {
        let s = TVState.stored
        let fresh = Date().timeIntervalSince(s.updated) < 120
        switch a {
        case .power(let on):
            // Sony has separate on and off codes, so no guessing about a toggle.
            guard let on else { return ["TvPower"] }
            return [on ? "WakeUp" : "PowerOff"]
        case .volumeUp(let n): return Array(repeating: "VolumeUp", count: max(1, min(n, 30)))
        case .volumeDown(let n): return Array(repeating: "VolumeDown", count: max(1, min(n, 30)))
        case .mute(let on):
            if let on, fresh, let m = s.muted, m == on { return [] }
            return ["Mute"]
        case .input(let id): return Inputs.key(id).map { [$0] }
        case .app(let id): return Apps.key(id).map { [$0] }
        case .key(let k): return [k]
        case .screen(let on):
            if on { return nil }
            return ["PicOff"]
        case .setVolume, .text: return nil
        }
    }

    private static func note(_ a: TVAction, _ path: TVPath) {
        var s = TVState.stored
        switch a {
        case .power(let on):
            if let on { s.power = on } else if let p = s.power { s.power = !p }
        case .mute(let on):
            if let on { s.muted = on } else if let m = s.muted { s.muted = !m }
        case .setVolume(let v): s.volume = v
        case .volumeUp(let n):
            let mx = s.maxVolume ?? 100
            s.volume = s.volume.map { min(mx, $0 + n) }
        case .volumeDown(let n): s.volume = s.volume.map { max(0, $0 - n) }
        case .input(let id):
            s.input = Inputs.label(id)
            s.inputURI = Inputs.find(id)?.uri
            s.power = true
        case .app(let id):
            s.input = Apps.label(id)
            s.inputURI = nil
            s.power = true
        case .key(let k):
            if k == "WakeUp" { s.power = true }
            if k == "PowerOff" { s.power = false }
            if k == "TvPower", let p = s.power { s.power = !p }
            if k == "Mute", let m = s.muted { s.muted = !m }
        case .screen(let on): s.screenOff = !on
        case .text: break
        }
        s.via = path.rawValue
        s.updated = .now
        TVState.stored = s
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Reads power, volume, what's on and the screen over Wi-Fi.
    @discardableResult
    static func refresh(cfg: TVConfig = .stored) async -> TVState {
        var s = TVState.stored
        guard let b = Bravia(cfg, timeout: 3) else { return s }
        do {
            s.power = try await b.power()
            if s.power == true {
                async let v = try? b.volume()
                async let scr = try? b.screenOff()
                async let on = nowOn(b)
                let (vol, screen, what) = await (v, scr, on)
                if let vol {
                    s.volume = vol.level
                    s.muted = vol.muted
                    s.maxVolume = vol.max
                }
                if let screen { s.screenOff = screen }
                if let what {
                    s.input = what.label
                    s.inputURI = what.uri
                }
            } else {
                s.screenOff = nil
            }
            s.via = TVPath.wifi.rawValue
            s.updated = .now
        } catch {
            // Standby with the network asleep: call it off.
            if (error as? BraviaError)?.unreachable == true {
                s.power = false
                s.updated = .now
            }
        }
        TVState.stored = s
        return s
    }

    /// What's on, as a label. "Apps" when an app is in front (the TV doesn't say which one).
    static func nowOn(_ b: Bravia) async -> (label: String, uri: String?)? {
        do {
            guard let p = try await b.playing() else { return ("Apps", nil) }
            if let uri = p.uri, let i = Inputs.find(uri) { return (i.name, uri) }
            return (p.title ?? "TV", p.uri)
        } catch {
            return nil
        }
    }
}

/// Sends IR through the Tuya blaster. Keeps one connection for a little while, then lets go
/// so Smart Life, Redshift, Subwave and the Afterglow bridge can still reach it (many blasters take one at a time).
actor IRSender {
    static let shared = IRSender()
    private var link: LocalLink?
    private var idle: Task<Void, Never>?
    private var listener: (@Sendable ([String: JSONValue]) -> Void)?
    /// While learning, the connection stays up.
    private var hold = false

    func send(_ code: String) async throws {
        let cfg = BlasterConfig.stored
        try await raw(IRCommand.send(code, cfg.format))
    }

    /// Any data points to the blaster (learn mode on/off). Reconnects once if the socket went stale.
    func raw(_ dps: [String: JSONValue]) async throws {
        let cfg = BlasterConfig.stored
        guard cfg.isReady else { throw AppError("Set up the IR blaster in Phosphor first.") }
        do {
            let l = try await open(cfg)
            try await l.set(dps)
        } catch {
            await drop()
            let l = try await open(cfg)
            try await l.set(dps)
        }
        armIdle()
    }

    func query() async throws -> [String: JSONValue] {
        let l = try await open(BlasterConfig.stored)
        armIdle()
        return try await l.query()
    }

    /// Gets every data point the blaster reports (learned codes arrive this way).
    func listen(_ f: (@Sendable ([String: JSONValue]) -> Void)?) {
        listener = f
    }

    func setHold(_ on: Bool) {
        hold = on
        if on { idle?.cancel() } else { armIdle() }
    }

    func deliver(_ dps: [String: JSONValue]) {
        listener?(dps)
    }

    func drop() async {
        idle?.cancel()
        if let l = link { await l.close() }
        link = nil
    }

    /// Opens (or reuses) the link. Returns the protocol version it settled on.
    @discardableResult
    func connect() async throws -> Double {
        let l = try await open(BlasterConfig.stored)
        armIdle()
        return l.version
    }

    private func open(_ cfg: BlasterConfig) async throws -> LocalLink {
        if let l = link, await l.isOpen { return l }
        guard let devId = cfg.devId, let key = cfg.localKey, let host = cfg.host else {
            throw AppError("Set up the IR blaster in Phosphor first.")
        }
        let onDPS: @Sendable ([String: JSONValue]) -> Void = { dps in Task { await IRSender.shared.deliver(dps) } }
        let onClose: @Sendable (String) -> Void = { _ in Task { await IRSender.shared.closed() } }
        if let v = cfg.version {
            let l = LocalLink(devId: devId, host: host, localKey: key, version: v, onDPS: onDPS, onClose: onClose)
            do {
                try await l.open()
                link = l
                return l
            } catch {
                await l.close()
            }
        }
        let r = try await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: [], probe: IRCommand.probes,
                                           onDPS: onDPS, onClose: onClose)
        var c = BlasterConfig.stored
        c.version = r.0.version
        BlasterConfig.stored = c
        link = r.0
        if !r.1.isEmpty { listener?(r.1) }
        return r.0
    }

    private func closed() {
        link = nil
    }

    private func armIdle() {
        idle?.cancel()
        guard !hold else { return }
        idle = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self.drop()
        }
    }
}

// MARK: - Presets

/// A saved setup: power on, an input or app, a volume, screen on or off, and any buttons.
struct TVPreset: Codable, Identifiable, Equatable, Hashable {
    var id = UUID().uuidString
    var name: String
    var icon: String
    var powerOn = true
    var input: String?
    var app: String?
    var volume: Int?
    var screenOff = false
    var keys: [String] = []

    var summary: String {
        if !powerOn { return "Power off" }
        var parts: [String] = []
        if let input { parts.append(Inputs.label(input)) }
        if let app { parts.append(Apps.label(app)) }
        if let volume { parts.append("vol \(volume)") }
        if screenOff { parts.append("screen off") }
        parts += keys.map(Keys.label)
        return parts.isEmpty ? "Power on" : parts.joined(separator: " · ")
    }

    static let defaults: [TVPreset] = [
        TVPreset(name: "Netflix", icon: "n.square.fill", app: "Netflix"),
        TVPreset(name: "YouTube", icon: "play.rectangle.fill", app: "YouTube"),
        TVPreset(name: "Music, screen off", icon: "music.note", screenOff: true),
        TVPreset(name: "Off", icon: "power", powerOn: false),
    ]
}

enum PresetStore {
    static func load() -> [TVPreset] { AppGroup.read([TVPreset].self, "presets.json") ?? TVPreset.defaults }
    static func save(_ p: [TVPreset]) { AppGroup.write(p, "presets.json") }
}

enum Presets {
    static func run(_ p: TVPreset) async throws {
        guard p.powerOn else {
            try await TV.perform(.power(false))
            return
        }
        let wasOff = TVState.stored.power != true
        try await TV.perform(.power(true))
        // Google TV takes a few seconds to take commands after waking.
        if wasOff { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        var failures: [String] = []
        var steps = 0
        func step(_ a: TVAction) async {
            steps += 1
            do { try await TV.perform(a) } catch { failures.append(error.localizedDescription) }
        }
        if let input = p.input { await step(.input(input)) }
        if let app = p.app { await step(.app(app)) }
        if let v = p.volume { await step(.setVolume(v)) }
        for k in p.keys {
            await step(.key(k))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if p.screenOff {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await step(.screen(false))
        }
        if steps > 0 && failures.count >= steps {
            throw AppError(failures.first ?? "That preset didn't go through.")
        }
    }
}
