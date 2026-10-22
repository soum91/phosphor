import Foundation

/// Sony's IP control: JSON-RPC over HTTP on port 80 (/sony/<service>), the same API the Sony and Google apps,
/// Home Assistant and Afterglow use, plus IRCC-IP for remote buttons. Auth is the TV's pre-shared key.
struct BraviaError: LocalizedError {
    let message: String
    var code: Int?
    var unreachable = false
    var auth = false

    init(_ m: String, code: Int? = nil, unreachable: Bool = false, auth: Bool = false) {
        message = m; self.code = code; self.unreachable = unreachable; self.auth = auth
    }
    var errorDescription: String? { message }

    /// "Illegal state": the TV is in standby, or nothing it can describe is playing (an app).
    var illegalState: Bool { code == 7 || code == 40005 }
}

struct BraviaInput: Codable, Hashable, Identifiable {
    var uri: String
    var title: String
    var label: String
    var connected: Bool
    var id: String { uri }
    /// The label if you named the input on the TV, else Sony's title ("HDMI 2").
    var name: String { label.isEmpty ? title : label }

    /// The remote key for this input, for IR.
    var key: String? {
        let u = uri.lowercased()
        if u.hasPrefix("extinput:hdmi"), let port = URLComponents(string: uri)?.queryItems?.first(where: { $0.name == "port" })?.value {
            return "Hdmi\(port)"
        }
        return nil
    }
}

struct BraviaApp: Codable, Hashable, Identifiable {
    var uri: String
    var title: String
    var icon: String?
    var id: String { uri }
    var iconURL: URL? { icon.flatMap(URL.init(string:)) }
}

struct BraviaSetting: Identifiable, Hashable {
    struct Choice: Hashable { var value: String; var title: String }
    var service: String
    var setMethod: String
    var setVersion: String
    var target: String
    var value: String
    var available: Bool
    var choices: [Choice]
    var min: Double?
    var max: Double?
    var step: Double?
    var id: String { service + "/" + target }

    var title: String { Keys.prettify(target) }
    var isRange: Bool { choices.isEmpty && min != nil && max != nil }
    var isToggle: Bool {
        let v = Set(choices.map { $0.value.lowercased() })
        return v == ["on", "off"]
    }
}

struct Bravia {
    let host: String
    let psk: String
    let timeout: Double

    init(host: String, psk: String, timeout: Double = 4) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.psk = psk
        self.timeout = timeout
    }

    init?(_ cfg: TVConfig, timeout: Double = 4) {
        guard cfg.hasWiFi else { return nil }
        self.init(host: cfg.host, psk: cfg.psk, timeout: timeout)
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    private func request(_ path: String) throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else { throw BraviaError("Bad TV address.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if !psk.isEmpty { req.setValue(psk, forHTTPHeaderField: "X-Auth-PSK") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await Self.session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError {
            switch e.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                throw BraviaError("The TV isn't answering on Wi-Fi.", unreachable: true)
            default:
                throw BraviaError(e.localizedDescription, unreachable: true)
            }
        }
    }

    // MARK: JSON-RPC

    /// Calls a method and returns its "result" array.
    @discardableResult
    func call(_ service: String, _ method: String, _ params: [Any] = [], version: String = "1.0") async throws -> [Any] {
        var req = try request("/sony/\(service)")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "id": 1, "params": params, "version": version])
        let (data, status) = try await send(req)
        if status == 401 || status == 403 {
            throw BraviaError("The TV turned down the pre-shared key. Check it matches Settings › Network › IP control on the TV.", code: status, auth: true)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 404 { throw BraviaError("That TV doesn't have Sony IP control (\(service)).", code: 404) }
            throw BraviaError("The TV sent something odd back (HTTP \(status)).", code: status)
        }
        if let err = obj["error"] as? [Any] {
            let code = (err.first as? Int) ?? (err.first as? NSNumber)?.intValue
            let msg = err.count > 1 ? "\(err[1])" : "error"
            if code == 403 || code == 401 || code == 40003 {
                throw BraviaError("The TV turned down the pre-shared key. Check it matches Settings › Network › IP control on the TV.", code: code, auth: true)
            }
            throw BraviaError("TV said: \(msg)\(code.map { " (\($0))" } ?? "")", code: code)
        }
        if let r = obj["result"] as? [Any] { return r }
        if let r = obj["results"] as? [Any] { return r }
        return []
    }

    /// Tries newer versions first and falls back when the TV says it doesn't know them.
    @discardableResult
    func callAny(_ service: String, _ method: String, _ params: [Any], versions: [String]) async throws -> [Any] {
        var last: Error = BraviaError("No version worked.")
        for v in versions {
            do { return try await call(service, method, params, version: v) } catch let e as BraviaError {
                last = e
                // 12 no such method, 14 unsupported version, 15 unsupported operation, 3 illegal argument.
                if e.unreachable || e.auth || !(e.code.map { [3, 12, 14, 15].contains($0) } ?? false) { throw e }
            }
        }
        throw last
    }

    private func firstObject(_ r: [Any]) -> [String: Any]? {
        if let o = r.first as? [String: Any] { return o }
        if let l = r.first as? [[String: Any]] { return l.first }
        return nil
    }

    private func list(_ r: [Any]) -> [[String: Any]] {
        if let l = r.first as? [[String: Any]] { return l }
        return r.compactMap { $0 as? [String: Any] }
    }

    // MARK: System

    /// True when the screen side is on ("active"), false in standby.
    func power() async throws -> Bool {
        let r = try await call("system", "getPowerStatus")
        return (firstObject(r)?["status"] as? String) == "active"
    }

    func setPower(_ on: Bool) async throws {
        try await call("system", "setPowerStatus", [["status": on]])
    }

    struct Info { var name: String?; var model: String?; var mac: String?; var generation: String? }

    func systemInfo() async throws -> Info {
        let o = firstObject(try await call("system", "getSystemInformation")) ?? [:]
        return Info(name: o["name"] as? String, model: o["model"] as? String,
                    mac: o["macAddr"] as? String, generation: o["generation"] as? String)
    }

    /// Answers without the key on every Bravia: good for "is this a Sony TV?".
    func interfaceInfo() async throws -> (model: String?, product: String?) {
        let o = firstObject(try await call("system", "getInterfaceInformation")) ?? [:]
        return (o["modelName"] as? String, o["productName"] as? String)
    }

    /// Every button the TV knows, by Sony's name ("VolumeUp") with its IRCC code.
    func remoteCodes() async throws -> [String: String] {
        let r = try await call("system", "getRemoteControllerInfo")
        var out: [String: String] = [:]
        let rows: [[String: Any]] = r.count > 1 ? (r[1] as? [[String: Any]] ?? []) : list(r)
        for row in rows {
            if let n = row["name"] as? String, let v = row["value"] as? String, !n.isEmpty, !v.isEmpty { out[n] = v }
        }
        return out
    }

    /// "pictureOff" means the screen is off but the TV keeps playing (audio only).
    func screenOff() async throws -> Bool {
        let r = try await call("system", "getPowerSavingMode")
        return (firstObject(r)?["mode"] as? String) == "pictureOff"
    }

    func setScreenOff(_ off: Bool) async throws {
        try await call("system", "setPowerSavingMode", [["mode": off ? "pictureOff" : "off"]])
    }

    func reboot() async throws { try await call("system", "requestReboot") }

    // MARK: Audio

    struct Volume { var level: Int; var muted: Bool; var max: Int; var target: String }

    func volume() async throws -> Volume {
        let rows = list(try await call("audio", "getVolumeInformation"))
        let o = rows.first { ($0["target"] as? String) == "speaker" } ?? rows.first ?? [:]
        func int(_ k: String) -> Int? { (o[k] as? Int) ?? (o[k] as? NSNumber)?.intValue }
        return Volume(level: int("volume") ?? 0, muted: (o["mute"] as? Bool) ?? false,
                      max: int("maxVolume") ?? 100, target: (o["target"] as? String) ?? "speaker")
    }

    /// Absolute ("25") or relative ("+2", "-1"). Shows the TV's volume bar where the firmware supports it.
    func setVolume(_ value: String, target: String = "speaker") async throws {
        do {
            try await call("audio", "setAudioVolume", [["target": target, "volume": value, "ui": "on"]], version: "1.2")
        } catch let e as BraviaError where !e.unreachable && !e.auth && (e.code.map { [3, 12, 14, 15].contains($0) } ?? false) {
            try await call("audio", "setAudioVolume", [["target": target, "volume": value]])
        }
    }

    func setMute(_ on: Bool) async throws {
        try await call("audio", "setAudioMute", [["status": on]])
    }

    // MARK: Content

    func inputs() async throws -> [BraviaInput] {
        let r = try await callAny("avContent", "getCurrentExternalInputsStatus", [], versions: ["1.1", "1.0"])
        return list(r).compactMap { o in
            guard let uri = o["uri"] as? String else { return nil }
            let conn = (o["connection"] as? Bool) ?? ((o["status"] as? String) == "true")
            return BraviaInput(uri: uri, title: (o["title"] as? String) ?? uri, label: (o["label"] as? String) ?? "", connected: conn)
        }
    }

    /// What's on: an input or channel. Nil when an app is in front (the TV can't say which).
    func playing() async throws -> (uri: String?, title: String?)? {
        do {
            let o = firstObject(try await call("avContent", "getPlayingContentInfo")) ?? [:]
            return (o["uri"] as? String, (o["title"] as? String) ?? (o["dispNum"] as? String))
        } catch let e as BraviaError where e.illegalState {
            return nil
        }
    }

    func setContent(_ uri: String) async throws {
        try await call("avContent", "setPlayContent", [["uri": uri]])
    }

    func apps() async throws -> [BraviaApp] {
        list(try await call("appControl", "getApplicationList")).compactMap { o in
            guard let uri = o["uri"] as? String, let title = o["title"] as? String else { return nil }
            return BraviaApp(uri: uri, title: title, icon: o["icon"] as? String)
        }
    }

    func launch(_ uri: String) async throws {
        try await call("appControl", "setActiveApp", [["uri": uri]])
    }

    /// Fills the text field that's focused on the TV (search boxes, logins).
    func type(_ text: String) async throws {
        do {
            try await call("appControl", "setTextForm", [["text": text]], version: "1.1")
        } catch let e as BraviaError where !e.unreachable && !e.auth && (e.code.map { [3, 12, 14, 15].contains($0) } ?? false) {
            // 1.0 takes the text on its own.
            try await call("appControl", "setTextForm", [text], version: "1.0")
        }
    }

    func closeApps() async throws { try await call("appControl", "terminateApps") }

    // MARK: Settings (picture, sound, speakers)

    struct SettingsGroup { var title: String; var service: String; var get: String; var set: String; var versions: [String] }

    static let settingGroups: [SettingsGroup] = [
        SettingsGroup(title: "Picture", service: "video", get: "getPictureQualitySettings", set: "setPictureQualitySettings", versions: ["1.0"]),
        SettingsGroup(title: "Sound", service: "audio", get: "getSoundSettings", set: "setSoundSettings", versions: ["1.1", "1.0"]),
        SettingsGroup(title: "Speakers", service: "audio", get: "getSpeakerSettings", set: "setSpeakerSettings", versions: ["1.0"]),
    ]

    func settings(_ g: SettingsGroup) async throws -> [BraviaSetting] {
        var used = g.versions.first ?? "1.0"
        var rows: [[String: Any]] = []
        var last: Error?
        for v in g.versions {
            do {
                rows = list(try await call(g.service, g.get, [["target": ""]], version: v))
                used = v
                last = nil
                break
            } catch {
                last = error
            }
        }
        if let last, rows.isEmpty { throw last }
        return rows.compactMap { o in
            guard let target = o["target"] as? String else { return nil }
            var s = BraviaSetting(service: g.service, setMethod: g.set, setVersion: used, target: target,
                                  value: Self.str(o["currentValue"]) ?? "", available: (o["isAvailable"] as? Bool) ?? true,
                                  choices: [], min: nil, max: nil, step: nil)
            for c in o["candidate"] as? [[String: Any]] ?? [] {
                if let mn = c["min"].flatMap(Self.num), let mx = c["max"].flatMap(Self.num), mx > mn {
                    s.min = mn; s.max = mx; s.step = c["step"].flatMap(Self.num) ?? 1
                } else if let v = Self.str(c["value"]), !v.isEmpty {
                    s.choices.append(.init(value: v, title: (c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Keys.prettify(v)))
                }
            }
            return s
        }
    }

    func apply(_ s: BraviaSetting, _ value: String) async throws {
        try await call(s.service, s.setMethod, [["settings": [["target": s.target, "value": value]]]], version: s.setVersion)
    }

    static func str(_ a: Any?) -> String? {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return nil
    }

    static func num(_ a: Any) -> Double? {
        if let n = a as? NSNumber { return n.doubleValue }
        if let s = a as? String { return Double(s) }
        return nil
    }

    // MARK: IRCC-IP

    /// Presses a remote button over Wi-Fi.
    func ircc(_ code: String) async throws {
        var req = try request("/sony/IRCC")
        req.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", forHTTPHeaderField: "SOAPACTION")
        let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(code)</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>
        """
        req.httpBody = Data(body.utf8)
        let (_, status) = try await send(req)
        if status == 401 || status == 403 {
            throw BraviaError("The TV turned down the pre-shared key.", code: status, auth: true)
        }
        guard status == 200 else { throw BraviaError("The TV didn't take that button (HTTP \(status)).", code: status) }
    }
}
