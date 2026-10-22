import Foundation
import Network
import Security

/// A small ADB client (the protocol `adb connect <ip>:5555` speaks), for what Sony's API can't do:
/// listing and opening sideloaded apps. The first connection makes the TV ask "Allow USB debugging?";
/// tick "Always allow from this computer" and it never asks again.
struct ADBError: LocalizedError {
    let message: String
    var needsApproval = false
    init(_ m: String, needsApproval: Bool = false) { message = m; self.needsApproval = needsApproval }
    var errorDescription: String? { message }
}

/// A sideloaded (or any non-Sony-listed) app, found over ADB.
struct SideApp: Codable, Hashable, Identifiable {
    var package: String
    /// Your name for it.
    var name: String?
    /// The app's own name, read from its APK.
    var label: String?
    /// True once its icon has been saved (icons/<package>.png in the App Group).
    var hasIcon: Bool?
    var id: String { package }
    var title: String { name ?? label ?? SideApp.guessName(package) }

    static func iconFile(_ pkg: String) -> String { "icon-\(pkg).png" }
    var iconData: Data? { hasIcon == true ? AppGroup.readData(SideApp.iconFile(package)) : nil }

    static let known: [String: String] = [
        "com.teamsmart.videomanager.tv": "SmartTube",
        "org.smartteam.smarttube.beta": "SmartTube Beta",
        "com.spocky.projengmenu": "Projectivy",
        "org.xbmc.kodi": "Kodi",
        "com.stremio.one": "Stremio",
        "com.liskovsoft.smarttubetv": "SmartTube",
        "com.liskovsoft.smarttubetv.beta": "SmartTube Beta",
        "tv.twitch.android.app": "Twitch",
        "com.cloudstream3.prerelease": "CloudStream",
        "com.lagradost.cloudstream3": "CloudStream",
        "is.xyz.mpv": "mpv",
        "org.videolan.vlc": "VLC",
        "com.plexapp.android": "Plex",
        "org.jellyfin.androidtv": "Jellyfin",
        "com.amazon.amazonvideo.livingroom": "Prime Video",
        "com.disney.disneyplus": "Disney+",
        "com.spotify.tv.android": "Spotify",
        "com.android.chrome": "Chrome",
        "org.mozilla.tv.firefox": "Firefox",
        "com.termux": "Termux",
        "com.wolf.firelauncher": "Wolf Launcher",
        "com.retroarch": "RetroArch",
        "com.moonlight_stream.moonlight": "Moonlight",
        "com.valvesoftware.steamlink": "Steam Link",
        "com.google.android.youtube.tvunplugged": "YouTube TV",
        "com.cetusplay.remoteservice": "CetusPlay",
        "com.estrongs.android.pop": "ES File Explorer",
        "com.dropbox.android": "Dropbox",
        "com.solid.explorer": "Solid Explorer",
        "com.android.vending": "Play Store",
    ]

    static func guessName(_ pkg: String) -> String {
        if let k = known[pkg] { return k }
        let skip: Set<String> = ["com", "org", "net", "tv", "android", "app", "apps", "io", "de", "uk", "co", "androidtv", "atv", "leanback", "free", "pro", "beta", "mobile", "ott", "player"]
        let parts = pkg.split(separator: ".").map(String.init)
        let pick = parts.reversed().first { !skip.contains($0.lowercased()) && $0.count > 2 } ?? parts.last ?? pkg
        return Keys.prettify(pick.prefix(1).uppercased() + pick.dropFirst())
    }
}

enum SideAppStore {
    static func load() -> [SideApp] { AppGroup.read([SideApp].self, "sideapps.json") ?? [] }
    static func save(_ a: [SideApp]) { AppGroup.write(a, "sideapps.json") }
}

// MARK: - Key

/// The RSA key the TV remembers. Kept in the App Group so the widget and Siri are the same "computer".
enum ADBKey {
    private static let file = "adbkey.der"

    static func privateKey() throws -> SecKey {
        if let data = AppGroup.readData(file),
           let k = SecKeyCreateWithData(data as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil) {
            return k
        }
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &err),
              let data = SecKeyCopyExternalRepresentation(k, &err) as Data? else {
            throw ADBError("Couldn't make an ADB key: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        AppGroup.writeData(data, file)
        return k
    }

    /// ADB's "computer" key string: its own RSAPublicKey struct (mincrypt), base64, then a name.
    static func publicKeyString() throws -> String {
        let priv = try privateKey()
        guard let pub = SecKeyCopyPublicKey(priv), let der = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw ADBError("Couldn't read the ADB public key.")
        }
        guard let (modulus, exponent) = parsePKCS1([UInt8](der)) else { throw ADBError("Couldn't parse the ADB public key.") }
        // Modulus as 64 little-endian 32-bit words.
        var m = modulus
        while m.first == 0 { m.removeFirst() }
        guard m.count <= 256 else { throw ADBError("Unexpected key size.") }
        m = [UInt8](repeating: 0, count: 256 - m.count) + m
        var n = [UInt32](repeating: 0, count: 64)
        for i in 0..<64 {
            let o = 256 - (i + 1) * 4
            n[i] = UInt32(m[o]) << 24 | UInt32(m[o + 1]) << 16 | UInt32(m[o + 2]) << 8 | UInt32(m[o + 3])
        }
        // n0inv = -1 / n[0] mod 2^32
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0inv = 0 &- inv
        // rr = (2^2048)^2 mod n, by doubling 1 four thousand and ninety six times.
        var x = [UInt32](repeating: 0, count: 65)
        x[0] = 1
        let n65 = n + [0]
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for i in 0..<65 {
                let v = x[i]
                x[i] = (v << 1) | carry
                carry = v >> 31
            }
            if !less(x, n65) { sub(&x, n65) }
        }
        var e: UInt32 = 0
        for b in exponent { e = e << 8 | UInt32(b) }
        var out: [UInt8] = []
        func le(_ v: UInt32) { out += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
        le(64)
        le(n0inv)
        n.forEach(le)
        x.prefix(64).forEach(le)
        le(e)
        return Data(out).base64EncodedString() + " obsidian@iphone"
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func sub(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }

    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    private static func parsePKCS1(_ d: [UInt8]) -> ([UInt8], [UInt8])? {
        var i = 0
        func length() -> Int? {
            guard i < d.count else { return nil }
            var l = Int(d[i]); i += 1
            if l & 0x80 != 0 {
                let n = l & 0x7f
                guard n <= 4, i + n <= d.count else { return nil }
                l = 0
                for _ in 0..<n { l = l << 8 | Int(d[i]); i += 1 }
            }
            return l
        }
        func integer() -> [UInt8]? {
            guard i < d.count, d[i] == 0x02 else { return nil }
            i += 1
            guard let l = length(), i + l <= d.count else { return nil }
            defer { i += l }
            return Array(d[i..<(i + l)])
        }
        guard d.first == 0x30 else { return nil }
        i = 1
        guard length() != nil, let n = integer(), let e = integer() else { return nil }
        return (n, e)
    }

    static func sign(_ token: [UInt8]) throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        // ADB's token is treated as an already-hashed SHA-1 digest.
        guard let sig = SecKeyCreateSignature(try privateKey(), .rsaSignatureDigestPKCS1v15SHA1, Data(token) as CFData, &err) as Data? else {
            throw ADBError("Couldn't sign the TV's challenge: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return [UInt8](sig)
    }
}

// MARK: - Connection

actor ADB {
    private enum Cmd {
        static let cnxn: UInt32 = 0x4e584e43, auth: UInt32 = 0x48545541, open: UInt32 = 0x4e45504f
        static let okay: UInt32 = 0x59414b4f, clse: UInt32 = 0x45534c43, wrte: UInt32 = 0x45545257
    }

    private struct Message { var cmd: UInt32; var arg0: UInt32; var arg1: UInt32; var data: [UInt8] }

    let host: String
    let port: UInt16
    private var conn: NWConnection?
    private var buffer: [UInt8] = []
    private var inbox: [Message] = []
    private var closed = false
    private var nextID: UInt32 = 1
    private var maxData = 256 * 1024

    init(host: String, port: UInt16 = 5555) {
        self.host = host
        self.port = port
    }

    /// Connects and authenticates. `approvalWait` is how long to wait for you to accept the prompt on the TV.
    func connect(approvalWait: Double = 0) async throws {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn = c
        do {
            try await LocalLink.waitReady(c, timeout: 4)
        } catch {
            throw ADBError("Nothing answered ADB at \(host):\(port). On the TV: Settings › System › About › tap Build 7 times, then Settings › System › Developer options › USB debugging on (and Network debugging if it's there).")
        }
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: Task { await self.markClosed() }
            default: break
            }
        }
        receive(c)
        try send(Cmd.cnxn, 0x0100_0000, UInt32(maxData), Array("host::obsidian\0".utf8))
        var sentKey = false
        var signed = false
        while true {
            let m = try await next([Cmd.cnxn, Cmd.auth], timeout: sentKey ? max(approvalWait, 3) : 6)
            if m.cmd == Cmd.cnxn {
                maxData = max(1024, min(Int(m.arg1), 256 * 1024))
                return
            }
            // AUTH TOKEN: sign it once; if the TV doesn't know our key, offer the key so it can ask you.
            guard m.arg0 == 1 else { continue }
            if !signed {
                signed = true
                try send(Cmd.auth, 2, 0, try ADBKey.sign(m.data))
            } else if !sentKey {
                sentKey = true
                try send(Cmd.auth, 3, 0, Array((try ADBKey.publicKeyString() + "\0").utf8))
                if approvalWait <= 0 {
                    throw ADBError("Check the TV: accept \"Allow USB debugging?\" and tick Always allow, then try again.", needsApproval: true)
                }
            }
        }
    }

    func close() {
        conn?.cancel()
        conn = nil
        closed = true
    }

    /// Runs a shell command and returns what it printed.
    func shell(_ command: String, timeout: Double = 10) async throws -> String {
        let local = nextID
        nextID += 1
        try send(Cmd.open, local, 0, Array("shell:\(command)\0".utf8))
        var remote: UInt32 = 0
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let m = try await next([Cmd.okay, Cmd.wrte, Cmd.clse], timeout: deadline.timeIntervalSinceNow, for: local)
            switch m.cmd {
            case Cmd.okay:
                remote = m.arg0
            case Cmd.wrte:
                remote = m.arg0
                out += m.data
                try send(Cmd.okay, local, remote, [])
            default:
                if remote != 0 { try? send(Cmd.clse, local, remote, []) }
                return String(decoding: out, as: UTF8.self)
            }
        }
        if remote != 0 { try? send(Cmd.clse, local, remote, []) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Plumbing

    private func markClosed() { closed = true }

    private func send(_ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ data: [UInt8]) throws {
        guard let c = conn, !closed else { throw ADBError("The ADB connection closed.") }
        var h: [UInt8] = []
        func le(_ v: UInt32) { h += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
        le(cmd); le(a0); le(a1); le(UInt32(data.count))
        le(data.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        le(cmd ^ 0xffff_ffff)
        c.send(content: Data(h + data), completion: .idempotent)
    }

    private nonisolated func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
            let bytes = data.map { [UInt8]($0) } ?? []
            Task { await self.ingest(bytes, ended: done || err != nil, c) }
        }
    }

    private func ingest(_ bytes: [UInt8], ended: Bool, _ c: NWConnection) {
        buffer += bytes
        while buffer.count >= 24 {
            func u32(_ i: Int) -> UInt32 { UInt32(buffer[i]) | UInt32(buffer[i + 1]) << 8 | UInt32(buffer[i + 2]) << 16 | UInt32(buffer[i + 3]) << 24 }
            let len = Int(u32(12))
            guard buffer.count >= 24 + len else { break }
            inbox.append(Message(cmd: u32(0), arg0: u32(4), arg1: u32(8), data: Array(buffer[24..<(24 + len)])))
            buffer.removeFirst(24 + len)
        }
        if ended { closed = true } else if c === conn { receive(c) }
    }

    private func next(_ cmds: Set<UInt32>, timeout: Double, for local: UInt32? = nil) async throws -> Message {
        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        while Date() < deadline {
            if let i = inbox.firstIndex(where: { cmds.contains($0.cmd) && (local == nil || $0.arg1 == local!) }) {
                return inbox.remove(at: i)
            }
            if closed { throw ADBError("The TV closed the ADB connection. If it asked to allow debugging, accept and try again.") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw ADBError("The TV didn't answer over ADB.")
    }
}

// MARK: - What the app uses

enum SideApps {
    /// One-shot: connect, run, disconnect. Fine for the odd launch from a widget or Siri.
    static func run(_ host: String, _ commands: [String], approvalWait: Double = 0) async throws -> [String] {
        let adb = ADB(host: host)
        defer { Task { await adb.close() } }
        try await adb.connect(approvalWait: approvalWait)
        var out: [String] = []
        for c in commands { out.append(try await adb.shell(c)) }
        return out
    }

    /// Third-party packages that have a launcher activity (TV or phone).
    static func list(_ adb: ADB) async throws -> [String] {
        var r: [String] = []
        for c in ["pm list packages -3",
                  "cmd package query-activities --components -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER",
                  "cmd package query-activities --components -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"] {
            r.append(try await adb.shell(c))
        }
        let third = r[0].split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("package:") ? String(s.dropFirst(8)) : nil
        }
        // query-activities --components prints "pkg/.Activity" lines; keep only apps you can actually open.
        let launchable = Set((r[1] + "\n" + r[2]).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let slash = s.firstIndex(of: "/") else { return nil }
            return String(s[..<slash])
        })
        let pkgs = launchable.isEmpty ? third : third.filter { launchable.contains($0) }
        return pkgs.sorted()
    }

    static func launch(_ host: String, _ pkg: String) async throws {
        let r = try await run(host, ["monkey -p \(pkg) -c android.intent.category.LEANBACK_LAUNCHER 1"])
        if r[0].contains("No activities found") || r[0].contains("aborted") {
            let r2 = try await run(host, ["monkey -p \(pkg) -c android.intent.category.LAUNCHER 1"])
            if r2[0].contains("No activities found") { throw ADBError("\(SideApp.guessName(pkg)) has nothing to open on a TV.") }
        }
    }
}
