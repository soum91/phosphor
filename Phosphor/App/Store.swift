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

    // Sideloaded apps, over ADB
    @Published var sideApps = SideAppStore.load() { didSet { if sideApps != oldValue { SideAppStore.save(sideApps); WidgetCenter.shared.reloadAllTimelines() } } }
    @Published var adbBusy = false
    @Published var adbMessage: String?

    // Remote layout and phone volume buttons
    @Published var layout = RemoteLayout.stored { didSet { if layout != oldValue { RemoteLayout.stored = layout } } }
    @Published var home = HomeLayout.stored { didSet { if home != oldValue { HomeLayout.stored = home } } }
    @Published var phoneVolumeButtons = (UserDefaults.standard.object(forKey: "phoneVolumeButtons") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(phoneVolumeButtons, forKey: "phoneVolumeButtons")
            updateVolumeButtons(active: phoneVolumeButtons)
        }
    }

    /// Side buttons drive the TV while the app is in front (and the TV isn't known to be off).
    func updateVolumeButtons(active: Bool) {
        let vb = VolumeButtons.shared
        guard active, phoneVolumeButtons, isSetUp else { vb.stop(); return }
        vb.shouldIntercept = { [weak self] in self?.state.power != false }
        vb.onStep = { [weak self] n in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await TV.perform(n > 0 ? .volumeUp(n) : .volumeDown(-n), cfg: self.tv)
                    self.state = TVState.stored
                } catch {
                    self.show(error.localizedDescription)
                }
            }
        }
        vb.start()
    }

    // IR blaster (same one Redshift and Subwave use)
    @Published var blaster = BlasterConfig.stored { didSet { if blaster != oldValue { BlasterConfig.stored = blaster } } }
    @Published var blasterState: LinkState = .off
    /// What each device on the Wi-Fi said during the last search, for when it goes wrong.
    @Published var blasterLog: [String] = []
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

    /// A remote button, optionally forced over one path (long-press › Send over Wi-Fi / IR).
    func press(_ k: String, via path: TVPath? = nil) {
        switch path {
        case nil:
            perform(.key(k))
        case .ir?:
            guard blaster.isReady else { show("Set up the IR blaster first."); return }
            testIR(k)
        case .wifi?:
            guard tv.hasWiFi else { show("Set up the TV on Wi-Fi first."); return }
            haptic.impactOccurred()
            var c = tv
            c.route = .wifi
            Task {
                do {
                    try await TV.perform(.key(k), cfg: c)
                    lastPath = .wifi
                    state = TVState.stored
                } catch {
                    show(error.localizedDescription)
                }
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

    // MARK: - Sideloaded apps (ADB)

    /// Packages Sony's own list already shows, so they don't appear twice.
    private func sonyListed(_ pkg: String) -> Bool {
        // Sony's URIs look like com.sony.dtv.<package>.<activity>.
        apps.contains { $0.uri.hasPrefix("com.sony.dtv.\(pkg).") }
    }

    /// Asks the TV for its third-party apps. The first time, the TV asks you to allow debugging.
    func loadSideApps() async {
        guard tv.hasWiFi else { adbMessage = "Set up the TV on Wi-Fi first."; return }
        adbBusy = true
        adbMessage = "Connecting… if the TV asks \"Allow USB debugging?\", tick Always allow and press Allow."
        defer { adbBusy = false }
        let adb = ADB(host: tv.host)
        defer { Task { await adb.close() } }
        do {
            try await adb.connect(approvalWait: 60)
            let listing = try await SideApps.list(adb)
            var next: [SideApp] = []
            // Every third-party app the Sony list doesn't already show, plus anything you added by hand.
            for p in listing.third where !sonyListed(p) {
                var a = sideApps.first { $0.package == p } ?? SideApp(package: p)
                a.launchable = listing.launchable.isEmpty ? nil : listing.launchable.contains(p)
                next.append(a)
            }
            for a in sideApps where a.pinned == true && !next.contains(where: { $0.package == a.package }) {
                next.append(a)
            }
            next.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            sideApps = next
            await readNames(adb, next.filter { $0.label == nil || $0.hasIcon == nil }.map(\.package))
            sideApps.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            adbMessage = sideApps.isEmpty ? "Connected. No sideloaded apps on the TV." : "\(sideApps.count) app\(sideApps.count == 1 ? "" : "s")."
        } catch {
            adbMessage = error.localizedDescription
        }
    }

    /// Real names and icons, straight from each APK. The list updates as each one comes in.
    private func readNames(_ adb: ADB, _ pkgs: [String]) async {
        for (n, pkg) in pkgs.enumerated() {
            adbMessage = "Reading names and icons \(n + 1) of \(pkgs.count)…"
            guard let r = try? await APKInfo.read(adb, package: pkg),
                  let i = sideApps.firstIndex(where: { $0.package == pkg }) else { continue }
            var a = sideApps[i]
            if let l = r.label { a.label = l }
            if let icon = r.icon {
                AppGroup.writeData(icon, SideApp.iconFile(pkg))
                a.hasIcon = true
            } else {
                a.hasIcon = false
            }
            sideApps[i] = a
        }
    }

    /// Every package on the TV, for the "Add any app" picker.
    func allPackages() async throws -> (third: [String], system: [String]) {
        let adb = ADB(host: tv.host)
        defer { Task { await adb.close() } }
        try await adb.connect(approvalWait: 60)
        return try await SideApps.everything(adb)
    }

    /// Adds any app by hand (system apps too) and reads its name and icon.
    func addSideApp(_ pkg: String) {
        if let i = sideApps.firstIndex(where: { $0.package == pkg }) {
            sideApps[i].pinned = true
        } else {
            sideApps.append(SideApp(package: pkg, pinned: true))
        }
        home.hiddenApps.removeAll { $0 == "side:" + pkg }
        Task {
            let adb = ADB(host: tv.host)
            defer { Task { await adb.close() } }
            guard (try? await adb.connect()) != nil else { return }
            await readNames(adb, [pkg])
            adbMessage = nil
        }
    }

    func open(_ side: SideApp) {
        haptic.impactOccurred()
        Task {
            do {
                if state.power != true {
                    try await TV.perform(.power(true), cfg: tv)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                try await TV.perform(.app("side:" + side.package), cfg: tv)
                state = TVState.stored
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func rename(_ side: SideApp, _ name: String) {
        guard let i = sideApps.firstIndex(of: side) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        sideApps[i].name = n.isEmpty ? nil : n
    }

    func hide(_ side: SideApp) { sideApps.removeAll { $0 == side } }

    // MARK: - TV setup

    /// Checks the address and key, then reads the TV's name, model and lists.
    func connectTV(host: String, psk: String) async -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return "Type the TV's IP address." }
        let b = Bravia(host: h, psk: psk, timeout: 4)
        do {
            _ = try await b.interfaceInfo()
        } catch let e as BraviaError where e.unreachable {
            return "Nothing answered at \(h). Check the IP, that the TV is on and on the same Wi-Fi, and that Obsidian has Local Network access (iOS Settings › Obsidian)."
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
        if d.isSub {
            setupError = "\(d.name) is paired through a hub, not on Wi-Fi by itself, so it can't be reached directly. Pick the Wi-Fi blaster, or re-pair it straight to Wi-Fi in Smart Life."
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

    /// Listens for the blaster's own broadcast while scanning the Wi-Fi for Tuya's port, then checks the key on
    /// every candidate at once. Prefers a device that answered with something encrypted with our key.
    func findBlaster() {
        guard let devId = blaster.devId, let key = blaster.localKey else { return }
        blasterState = .searching("Scanning your Wi-Fi…")
        blasterLog = []
        Task {
            await IRSender.shared.drop()
            async let heardList = LocalScan.listen(seconds: 7)
            let scanned = await LocalScan.openHosts { n in
                Task { @MainActor in
                    if case .searching = Store.shared.blasterState { Store.shared.blasterState = .searching("Scanning your Wi-Fi… \(n)/254") }
                }
            }
            let heardAll = await heardList
            let heard = heardAll.first { $0.devId == devId }
            var log: [String] = []
            if let heard {
                log.append("Blaster announced itself at \(heard.ip), protocol \(heard.version).")
            } else if !heardAll.isEmpty {
                log.append("Heard \(heardAll.count) Tuya broadcast\(heardAll.count == 1 ? "" : "s"), none from this blaster.")
            }
            var hosts = scanned
            if let heard { hosts.removeAll { $0 == heard.ip }; hosts.insert(heard.ip, at: 0) }
            if hosts.isEmpty {
                blasterLog = log
                blasterState = .failed("Nothing on your Wi-Fi answered on Tuya's port. Allow Local Network for Obsidian in iOS Settings, or type the blaster's IP.")
                return
            }
            blasterState = .searching("Checking the key on \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s")…")

            // The blaster's own broadcast is definitive: try it first, with the version it gave.
            if let heard, let r = try? await LocalLink.detectFull(devId: devId, host: heard.ip, localKey: key, knownDPs: [], timeout: 3,
                                                                    versions: [heard.version] + [3.3, 3.4, 3.5].filter { $0 != heard.version },
                                                                    probe: IRCommand.probes, onDPS: { _ in }, onClose: { _ in }) {
                await r.link.close()
                blasterLog = log
                useBlaster(host: heard.ip, version: r.link.version)
                return
            }

            var strong: (String, Double)?
            var weak: [(String, Double)] = []
            await withTaskGroup(of: (String, Double?, KeyProof?, String?).self) { group in
                for host in hosts {
                    group.addTask {
                        do {
                            let r = try await LocalLink.detectFull(devId: devId, host: host, localKey: key, knownDPs: [], timeout: 3,
                                                                   probe: IRCommand.probes, onDPS: { _ in }, onClose: { _ in })
                            await r.link.close()
                            return (host, r.link.version, r.proof, nil)
                        } catch {
                            return (host, nil, nil, LocalLink.short(error))
                        }
                    }
                }
                for await (host, version, proof, err) in group {
                    if let version, let proof {
                        log.append("\(host): took the key (protocol \(version)\(proof == .weak ? ", acknowledged only" : "")).")
                        if proof == .strong, strong == nil { strong = (host, version) } else if proof == .weak { weak.append((host, version)) }
                    } else {
                        log.append("\(host): \(err ?? "no answer")")
                    }
                }
            }
            blasterLog = log
            if let strong {
                useBlaster(host: strong.0, version: strong.1)
            } else if weak.count == 1 {
                useBlaster(host: weak[0].0, version: weak[0].1)
            } else if weak.count > 1 {
                blasterState = .failed("\(weak.count) devices acknowledged but none proved the key (\(weak.map { $0.0 }.joined(separator: ", "))). Type the blaster's IP from your router.")
            } else {
                var why = "Found \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s") but none took the blaster's key."
                if let d = devices.first(where: { $0.id == devId }) {
                    if d.isSub { why += " Smart Life says this blaster is paired through a hub, so it has no Wi-Fi connection of its own." }
                    else if !d.online { why += " Smart Life says the blaster is offline." }
                }
                why += " Close Smart Life and the other blaster apps (it may only take one connection at a time), then try again. If you re-paired it, refresh the key."
                blasterState = .failed(why)
            }
        }
    }

    private func useBlaster(host: String, version: Double) {
        blaster.host = host
        blaster.version = version
        connectBlaster()
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
