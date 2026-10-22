import SwiftUI
import UIKit
import WidgetKit

enum LinkState: Equatable {
    case off, searching(String), connecting, connected(Double), failed(String)

    var text: String {
        switch self {
        case .off: return "Not connected"
        case .searching(let s): return s
        case .connecting: return "Connecting…"
        case .connected(let v): return "Connected (Tuya \(String(format: "%.1f", v)))"
        case .failed(let e): return e
        }
    }
    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isBusy: Bool {
        switch self {
        case .searching, .connecting: return true
        default: return false
        }
    }
}

struct LearnSession: Identifiable, Equatable {
    enum Phase: Equatable { case starting, waiting, captured(Int), failed(String) }
    let id = UUID()
    var keyID: String
    var label: String
    var phase: Phase = .starting
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // TV
    @Published var tv = TVConfig.stored { didSet { if tv != oldValue { TVConfig.stored = tv } } }
    @Published var state = TVState.stored
    @Published var inputs = InputCache.load()
    @Published var apps = AppCache.load()
    @Published var remote = RemoteCodes.load()
    @Published var wifiReachable: Bool?
    @Published var authFailed = false
    @Published var lastPath: TVPath?
    @Published var volumeDraft: Double?

    @Published var presets = PresetStore.load() { didSet { if presets != oldValue { PresetStore.save(presets) } } }

    // IR blaster (same one Redshift and Subwave use)
    @Published var blaster = BlasterConfig.stored { didSet { if blaster != oldValue { BlasterConfig.stored = blaster } } }
    @Published var blasterState: LinkState = .off
    @Published var codes = LearnedCodes.load() { didSet { if codes != oldValue { LearnedCodes.save(codes) } } }
    @Published var learning: LearnSession?
    @Published var token: TuyaToken? = TokenStore.load()
    @Published var devices: [DeviceInfo] = []
    @Published var loadingDevices = false
    @Published var setupError: String?

    @Published var toast: String?

    /// The TV's built-in Chromecast, for what's playing.
    let cast = CastClient()
    private var poller: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var learnTimeout: Task<Void, Never>?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var isSetUp: Bool { tv.hasWiFi || blaster.isReady }

    // MARK: - Polling

    func startPolling() {
        poller?.cancel()
        if tv.hasWiFi { cast.connect(host: tv.host) }
        poller = Task {
            var tick = 0
            while !Task.isCancelled {
                await refresh(full: tick % 6 == 0)
                tick += 1
                try? await Task.sleep(nanoseconds: (state.power == true ? 3 : 8) * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
        cast.disconnect()
    }

    func refresh(full: Bool = false) async {
        guard tv.hasWiFi else {
            state = TVState.stored
            return
        }
        let before = state
        let s = await TV.refresh(cfg: tv)
        if volumeDraft == nil { state = s } else { var t = s; t.volume = state.volume; state = t }
        wifiReachable = s.updated > Date().addingTimeInterval(-10) && s.via == TVPath.wifi.rawValue
        if before.power != s.power || before.volume != s.volume || before.muted != s.muted || before.screenOff != s.screenOff {
            WidgetCenter.shared.reloadAllTimelines()
        }
        if s.power == true, full || inputs.isEmpty || apps.isEmpty || remote.isEmpty {
            await loadLists()
        }
    }

    /// Inputs, apps and the TV's own button list. Kept for the widget, Siri and IR.
    func loadLists() async {
        guard let b = Bravia(tv) else { return }
        async let i = try? b.inputs()
        async let a = try? b.apps()
        async let r = try? b.remoteCodes()
        let (ins, aps, rem) = await (i, a, r)
        if let ins, !ins.isEmpty, ins != inputs { inputs = ins; InputCache.save(ins) }
        if let aps, !aps.isEmpty, aps != apps { apps = aps; AppCache.save(aps) }
        if let rem, !rem.isEmpty, rem != remote { remote = rem; RemoteCodes.save(rem) }
    }

    // MARK: - Commands

    func perform(_ a: TVAction) {
        haptic.impactOccurred()
        Task {
            do {
                let path = try await TV.perform(a, cfg: tv)
                lastPath = path
                authFailed = false
                state = TVState.stored
                if case .power(let on) = a, on == false { Donate.off() }
            } catch {
                if (error as? BraviaError)?.auth == true { authFailed = true }
                show(error.localizedDescription)
            }
        }
    }

    func togglePower() {
        switch state.power {
        case true?: perform(.power(false))
        case false?: perform(.power(true))
        default: perform(.power(nil))
        }
    }

    func setVolumeLive(_ v: Double) {
        volumeDraft = v
        state.volume = Int(v.rounded())
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await TV.perform(.setVolume(Int(v.rounded())), cfg: tv)
            } catch {
                show(error.localizedDescription)
            }
            if volumeDraft == v { volumeDraft = nil }
        }
    }

    func run(_ p: TVPreset) {
        haptic.impactOccurred()
        show("\(p.name)…")
        Task {
            do {
                try await Presets.run(p)
                Donate.preset(p)
                show(p.name)
                await refresh()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func open(_ app: BraviaApp) {
        haptic.impactOccurred()
        Task {
            do {
                if state.power != true {
                    try await TV.perform(.power(true), cfg: tv)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                try await TV.perform(.app(app.uri), cfg: tv)
                state = TVState.stored
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    // MARK: - TV setup

    /// Checks the address and key, then reads the TV's name, model and lists.
    func connectTV(host: String, psk: String) async -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return "Type the TV's IP address." }
        let b = Bravia(host: h, psk: psk, timeout: 4)
        do {
            _ = try await b.interfaceInfo()
        } catch let e as BraviaError where e.unreachable {
            return "Nothing answered at \(h). Check the IP, that the TV is on and on the same Wi-Fi, and that Phosphor has Local Network access (iOS Settings › Phosphor)."
        } catch {
            return "\(h) answered but doesn't look like a Sony TV with IP control: \(error.localizedDescription)"
        }
        // Power status answers without the key; system info doesn't, so it proves the key.
        do {
            _ = try await b.systemInfo()
        } catch let e as BraviaError where e.auth {
            return psk.isEmpty
                ? "The TV wants a pre-shared key. On the TV: Settings › Network & Internet › Home network › IP control › Authentication › Normal and Pre-Shared Key, set a key, and type it here."
                : "The TV turned down that key. Check Settings › Network & Internet › Home network › IP control › Pre-Shared Key on the TV."
        } catch {
            // Anything but a key problem is fine here (some firmware is picky in standby).
        }
        var t = tv
        t.host = h
        t.psk = psk
        if let info = try? await b.systemInfo() {
            if let m = info.model, !m.isEmpty { t.model = m }
            t.mac = info.mac
            if t.name == TVConfig().name, let m = t.model { t.name = "Bravia \(m.replacingOccurrences(of: "XR-", with: "").replacingOccurrences(of: "KD-", with: ""))" }
        }
        tv = t
        authFailed = false
        cast.disconnect()
        cast.connect(host: h)
        await refresh(full: true)
        await loadLists()
        return nil
    }

    func forgetTV() {
        cast.disconnect()
        var t = TVConfig()
        t.route = blaster.isReady ? .ir : .auto
        tv = t
        inputs = []; apps = []; remote = [:]
        InputCache.save([]); AppCache.save([]); RemoteCodes.save([:])
        state = TVState()
        TVState.stored = state
    }

    // MARK: - Smart Life (once, for the blaster's local key)

    func signedIn(_ t: TuyaToken) {
        TokenStore.save(t)
        token = t
        Task { await loadDevices() }
    }

    func signOutCloud() {
        TokenStore.clear()
        token = nil
        devices = []
    }

    func loadDevices() async {
        guard let token else { return }
        loadingDevices = true
        setupError = nil
        defer { loadingDevices = false }
        do {
            let list = try await TuyaClient(token: token).allDevices()
            devices = list.sorted { a, b in
                if a.isBlaster != b.isBlaster { return a.isBlaster }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            if devices.isEmpty { setupError = "No devices came back from Smart Life." }
        } catch {
            if let te = error as? TuyaError, te.isAuth { signOutCloud() }
            setupError = error.localizedDescription
        }
    }

    func choose(_ d: DeviceInfo) {
        guard let key = d.localKey, !key.isEmpty else {
            setupError = "Smart Life didn't hand over a local key for \(d.name)."
            return
        }
        setBlaster(devId: d.id, key: key, name: d.name)
    }

    func setBlaster(devId: String, key: String, name: String?, host: String? = nil) {
        let same = blaster.devId == devId
        Task { await IRSender.shared.drop() }
        var b = blaster
        b.devId = devId
        b.localKey = key
        b.name = name ?? b.name ?? "IR blaster"
        if !same { b.host = nil; b.version = nil; b.detected = nil }
        if let host, !host.isEmpty { b.host = host; b.version = nil }
        blaster = b
        if b.host == nil { findBlaster() } else { connectBlaster() }
    }

    func forgetBlaster() {
        Task { await IRSender.shared.drop() }
        blaster = BlasterConfig()
        blasterState = .off
        if tv.route == .ir { tv.route = .auto }
    }

    func setBlasterHost(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        Task { await IRSender.shared.drop() }
        blaster.host = h
        blaster.version = nil
        connectBlaster()
    }

    func refreshKey() async {
        guard let devId = blaster.devId else { return }
        await loadDevices()
        if let d = devices.first(where: { $0.id == devId }), let key = d.localKey, !key.isEmpty {
            if key != blaster.localKey {
                blaster.localKey = key
                await IRSender.shared.drop()
                connectBlaster()
                show("Got a new local key")
            } else {
                show("Key is already current")
            }
        }
    }

    func connectBlaster() {
        guard blaster.isReady else { return }
        blasterState = .connecting
        Task {
            await IRSender.shared.listen { dps in Task { @MainActor in Store.shared.receiveIR(dps) } }
            do {
                let v = try await IRSender.shared.connect()
                var b = BlasterConfig.stored
                if b.detected == nil {
                    var f: IRFormat?
                    if let dps = try? await IRSender.shared.query() { f = IRCommand.hint(dps) }
                    if f == nil { f = await probeFormat() }
                    b.detected = f
                }
                blaster = b
                blasterState = .connected(v)
                if !tv.hasWiFi && tv.route == .auto { tv.route = .ir }
            } catch {
                blaster = BlasterConfig.stored
                blasterState = .failed("Couldn't reach the blaster: \(error.localizedDescription)")
            }
        }
    }

    /// Same trick as tinytuya: poke both formats with a harmless "exit learning" and see which data point answers.
    private var seenDPs: Set<String> = []
    private func probeFormat() async -> IRFormat? {
        seenDPs = []
        try? await IRSender.shared.raw(IRCommand.studyExit(.classic))
        try? await IRSender.shared.raw(IRCommand.studyExit(.modern))
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let dps = try? await IRSender.shared.query(), let h = IRCommand.hint(dps) { return h }
        if seenDPs.contains("201") || seenDPs.contains("202") { return .classic }
        if seenDPs.contains("1") || seenDPs.contains("2") { return .modern }
        return nil
    }

    /// Scans the Wi-Fi for anything on Tuya's port, then tries the blaster's key on all of them at once.
    func findBlaster() {
        guard let devId = blaster.devId, let key = blaster.localKey else { return }
        blasterState = .searching("Scanning your Wi-Fi…")
        Task {
            await IRSender.shared.drop()
            let hosts = await LocalScan.openHosts { n in
                Task { @MainActor in
                    if case .searching = Store.shared.blasterState { Store.shared.blasterState = .searching("Scanning your Wi-Fi… \(n)/254") }
                }
            }
            if hosts.isEmpty {
                blasterState = .failed("Nothing on your Wi-Fi answered on Tuya's port. Allow Local Network for Phosphor in iOS Settings, or type the blaster's IP.")
                return
            }
            blasterState = .searching("Trying the key on \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s")…")
            let found: (String, Double)? = await withTaskGroup(of: (String, Double)?.self) { group in
                for host in hosts {
                    group.addTask {
                        guard let r = try? await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: [],
                                                                  onDPS: { _ in }, onClose: { _ in }) else { return nil }
                        await r.0.close()
                        return (host, r.0.version)
                    }
                }
                for await r in group {
                    if let r { group.cancelAll(); return r }
                }
                return nil
            }
            if let found {
                blaster.host = found.0
                blaster.version = found.1
                connectBlaster()
            } else {
                blasterState = .failed("Found \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s") but none took the blaster's key. If you re-paired it, refresh the key.")
            }
        }
    }

    // MARK: - IR learning

    func receiveIR(_ dps: [String: JSONValue]) {
        guard !dps.isEmpty else { return }
        seenDPs.formUnion(dps.keys)
        guard var s = learning, s.phase == .waiting || s.phase == .starting, let got = IRCommand.learned(in: dps) else { return }
        if blaster.forced == nil, blaster.detected != got.format { blaster.detected = got.format }
        codes[s.keyID] = got.code
        s.phase = .captured(IRPulses.pulses(got.code)?.count ?? 0)
        learning = s
        learnTimeout?.cancel()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format))
            await IRSender.shared.setHold(false)
        }
    }

    func startLearn(_ keyID: String) {
        guard blaster.isReady else { show("Set up the IR blaster first."); return }
        learnTimeout?.cancel()
        var s = learning ?? LearnSession(keyID: keyID, label: Keys.label(keyID))
        s.keyID = keyID
        s.label = Keys.label(keyID)
        s.phase = .starting
        learning = s
        Task {
            await IRSender.shared.listen { dps in Task { @MainActor in Store.shared.receiveIR(dps) } }
            await IRSender.shared.setHold(true)
            do {
                let f = blaster.format
                try await IRSender.shared.raw(IRCommand.studyExit(f))
                try await Task.sleep(nanoseconds: 150_000_000)
                try await IRSender.shared.raw(IRCommand.study(f))
                if learning?.phase == .starting { learning?.phase = .waiting }
                learnTimeout = Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, learning?.phase == .waiting else { return }
                    learning?.phase = .failed("Nothing came in. Hold the Sony remote 5 to 10 cm from the blaster, aim at it, and press once firmly. (The Bravia voice remote is Bluetooth for some buttons; those can't be learned.)")
                    try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format))
                    await IRSender.shared.setHold(false)
                }
            } catch {
                learning?.phase = .failed(error.localizedDescription)
                await IRSender.shared.setHold(false)
            }
        }
    }

    func endLearn() {
        learnTimeout?.cancel()
        if let s = learning, s.phase == .waiting || s.phase == .starting {
            Task { try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format)) }
        }
        Task { await IRSender.shared.setHold(false) }
        learning = nil
    }

    func testIR(_ keyID: String) {
        guard let code = Keys.ir(keyID, learned: codes, remote: remote) else { show("No IR code for that button yet."); return }
        haptic.impactOccurred()
        Task {
            do { try await IRSender.shared.send(code) } catch { show(error.localizedDescription) }
        }
    }

    func importRedshift(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url), let got = LearnedCodes.fromRedshift(d) else {
            show("No TV remote in that file. In Redshift: Settings › Export remotes.")
            return
        }
        if got.isEmpty { show("Redshift's TV remote has no learned buttons yet."); return }
        codes.merge(got) { _, new in new }
        show("Imported \(got.count) button\(got.count == 1 ? "" : "s") from Redshift")
    }

    // MARK: - Presets

    func savePreset(_ p: TVPreset) {
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func deletePreset(_ id: String) { presets.removeAll { $0.id == id } }

    // MARK: - Messages

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
}
