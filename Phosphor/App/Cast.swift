import Foundation
import Network

/// A small Google Cast (CASTV2) client: TLS on port 8009, length-prefixed protobuf CastMessages
/// carrying JSON. Enough to read what's playing on the TV and to play, pause, skip, seek, stop
/// and set the cast volume. Protocol from the open Cast receiver docs and pychromecast.

struct CastMedia: Equatable {
    var title: String?
    var subtitle: String?
    var artURL: URL?
    var duration: Double?
    var position: Double = 0
    var positionAt: Date = .now
    var playerState: String = "IDLE"     // PLAYING, PAUSED, BUFFERING, IDLE
    var mediaSessionId: Int?
    var supported: Int = 0

    var isPlaying: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }
    var livePosition: Double {
        guard playerState == "PLAYING" else { return position }
        let p = position + Date().timeIntervalSince(positionAt)
        return duration.map { min(p, $0) } ?? p
    }
    // supportedMediaCommands bits
    var canPause: Bool { supported & 1 != 0 }
    var canSeek: Bool { supported & 2 != 0 }
    var canNext: Bool { supported & 64 != 0 || supported == 0 }
    var canPrev: Bool { supported & 128 != 0 || supported == 0 }
}

struct CastStatus: Equatable {
    var app: String?
    var appId: String?
    var isIdleScreen = true
    var sessionId: String?
    var transportId: String?
    var hasMedia = false
    var volume: Double?
    var muted = false
    var media: CastMedia?
}

@MainActor
final class CastClient: ObservableObject {
    @Published private(set) var status = CastStatus()
    @Published private(set) var connected = false

    private var conn: NWConnection?
    private var buffer = Data()
    private var requestID = 1
    private var heartbeat: Task<Void, Never>?
    private var mediaPoll: Task<Void, Never>?
    private var host: String?
    private var mediaConnectedTo: String?
    private let sender = "sender-phosphor"

    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    // MARK: Connection

    func connect(host: String) {
        if self.host == host, conn != nil { return }
        disconnect()
        self.host = host
        let tls = NWProtocolTLS.Options()
        // Cast devices present a Google-issued device cert that iOS can't verify by name; it's on your LAN.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(host: NWEndpoint.Host(host), port: 8009, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.state(state) }
        }
        c.start(queue: .main)
        receive()
    }

    func disconnect() {
        heartbeat?.cancel(); heartbeat = nil
        mediaPoll?.cancel(); mediaPoll = nil
        conn?.cancel()
        conn = nil
        connected = false
        buffer.removeAll()
        mediaConnectedTo = nil
    }

    private func state(_ s: NWConnection.State) {
        switch s {
        case .ready:
            connected = true
            send(NS.connection, ["type": "CONNECT"], to: "receiver-0")
            send(NS.receiver, ["type": "GET_STATUS"], to: "receiver-0")
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.send(NS.heartbeat, ["type": "PING"], to: "receiver-0", withID: false)
                }
            }
            mediaPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self?.poll()
                }
            }
        case .failed, .cancelled:
            let h = host
            disconnect()
            host = h
        default: break
        }
    }

    func poll() {
        send(NS.receiver, ["type": "GET_STATUS"], to: "receiver-0")
        if let t = status.transportId, status.hasMedia { send(NS.media, ["type": "GET_STATUS"], to: t) }
    }

    // MARK: Commands

    func setVolume(_ level: Double) {
        send(NS.receiver, ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))]], to: "receiver-0")
    }

    func setMuted(_ m: Bool) {
        send(NS.receiver, ["type": "SET_VOLUME", "volume": ["muted": m]], to: "receiver-0")
    }

    func playPause() {
        guard let m = status.media else { return }
        media(m.isPlaying ? "PAUSE" : "PLAY")
    }

    func next() { media("QUEUE_NEXT", type: "QUEUE_UPDATE", extra: ["jump": 1]) }
    func previous() { media("QUEUE_PREV", type: "QUEUE_UPDATE", extra: ["jump": -1]) }

    func seek(_ seconds: Double) {
        media("SEEK", extra: ["currentTime": max(0, seconds)])
        status.media?.position = seconds
        status.media?.positionAt = .now
    }

    /// Stops whatever app is casting to the TV.
    func stopApp() {
        guard let sid = status.sessionId else { return }
        send(NS.receiver, ["type": "STOP", "sessionId": sid], to: "receiver-0")
    }

    private func media(_ name: String, type: String? = nil, extra: [String: Any] = [:]) {
        guard let t = status.transportId, let id = status.media?.mediaSessionId else { return }
        // Apps differ: send the queue form and the plain form, receivers ignore what they don't know.
        var body: [String: Any] = ["type": type ?? name, "mediaSessionId": id]
        for (k, v) in extra { body[k] = v }
        send(NS.media, body, to: t)
        if type != nil {
            var plain: [String: Any] = ["type": name, "mediaSessionId": id]
            for (k, v) in extra where k != "jump" { plain[k] = v }
            send(NS.media, plain, to: t)
        }
        if name == "PAUSE" { status.media?.position = status.media?.livePosition ?? 0; status.media?.playerState = "PAUSED" }
        if name == "PLAY" { status.media?.positionAt = .now; status.media?.playerState = "PLAYING" }
    }

    // MARK: Wire format

    private func send(_ ns: String, _ payload: [String: Any], to dest: String, withID: Bool = true) {
        guard let conn, connected else { return }
        var p = payload
        if withID { p["requestId"] = requestID; requestID += 1 }
        guard let json = try? JSONSerialization.data(withJSONObject: p), let text = String(data: json, encoding: .utf8) else { return }
        var msg = Data()
        msg += Proto.varintField(1, 0)                 // protocol_version CASTV2_1_0
        msg += Proto.stringField(2, sender)
        msg += Proto.stringField(3, dest)
        msg += Proto.stringField(4, ns)
        msg += Proto.varintField(5, 0)                 // payload_type STRING
        msg += Proto.stringField(6, text)
        var frame = Data()
        let n = UInt32(msg.count)
        frame += [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
        frame += msg
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer += data; self.drain() }
                if done || err != nil { self.state(.cancelled); return }
                self.receive()
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard buffer.count >= 4 + n else { return }
            let msg = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + n)
            let f = Proto.fields(msg)
            guard let ns = f[4], let payload = f[6],
                  let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            handle(String(decoding: ns, as: UTF8.self), obj, from: f[2].map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
    }

    private func handle(_ ns: String, _ obj: [String: Any], from source: String) {
        let type = obj["type"] as? String ?? ""
        switch (ns, type) {
        case (NS.heartbeat, "PING"):
            send(NS.heartbeat, ["type": "PONG"], to: source, withID: false)
        case (NS.receiver, "RECEIVER_STATUS"):
            receiverStatus(obj["status"] as? [String: Any] ?? [:])
        case (NS.media, "MEDIA_STATUS"):
            mediaStatus(obj["status"] as? [[String: Any]] ?? [])
        case (NS.connection, "CLOSE"):
            if source == mediaConnectedTo { mediaConnectedTo = nil }
        default:
            break
        }
    }

    private func receiverStatus(_ s: [String: Any]) {
        var st = status
        if let v = s["volume"] as? [String: Any] {
            st.volume = (v["level"] as? NSNumber)?.doubleValue
            st.muted = v["muted"] as? Bool ?? false
        }
        let apps = s["applications"] as? [[String: Any]] ?? []
        if let a = apps.first {
            st.app = a["displayName"] as? String
            st.appId = a["appId"] as? String
            st.isIdleScreen = a["isIdleScreen"] as? Bool ?? false
            st.sessionId = a["sessionId"] as? String
            st.transportId = a["transportId"] as? String
            let spaces = (a["namespaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            st.hasMedia = spaces.contains(NS.media)
        } else {
            st.app = nil; st.appId = nil; st.isIdleScreen = true
            st.sessionId = nil; st.transportId = nil; st.hasMedia = false; st.media = nil
        }
        status = st
        if let t = st.transportId, st.hasMedia, mediaConnectedTo != t {
            mediaConnectedTo = t
            send(NS.connection, ["type": "CONNECT"], to: t)
            send(NS.media, ["type": "GET_STATUS"], to: t)
        }
    }

    private func mediaStatus(_ list: [[String: Any]]) {
        guard let s = list.first else { status.media = nil; return }
        var m = status.media ?? CastMedia()
        if let id = (s["mediaSessionId"] as? NSNumber)?.intValue { m.mediaSessionId = id }
        if let st = s["playerState"] as? String { m.playerState = st }
        if let t = (s["currentTime"] as? NSNumber)?.doubleValue { m.position = t; m.positionAt = .now }
        if let sup = (s["supportedMediaCommands"] as? NSNumber)?.intValue { m.supported = sup }
        if let media = s["media"] as? [String: Any] {
            if let d = (media["duration"] as? NSNumber)?.doubleValue, d > 0 { m.duration = d }
            if let meta = media["metadata"] as? [String: Any] {
                m.title = meta["title"] as? String
                m.subtitle = (meta["artist"] as? String) ?? (meta["albumArtist"] as? String) ?? (meta["subtitle"] as? String)
                if let album = meta["albumName"] as? String, let sub = m.subtitle { m.subtitle = "\(sub) · \(album)" }
                if let img = (meta["images"] as? [[String: Any]])?.first?["url"] as? String { m.artURL = URL(string: img) }
            }
        }
        status.media = m
    }
}

/// Just enough protobuf for CastMessage.
enum Proto {
    static func varint(_ v: UInt64) -> Data {
        var v = v, out = Data()
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func varintField(_ n: Int, _ v: UInt64) -> Data { varint(UInt64(n << 3)) + varint(v) }

    static func stringField(_ n: Int, _ s: String) -> Data {
        let d = Data(s.utf8)
        return varint(UInt64(n << 3 | 2)) + varint(UInt64(d.count)) + d
    }

    /// Length-delimited fields by number. Varint fields are skipped (we don't need them).
    static func fields(_ d: Data) -> [Int: Data] {
        let b = [UInt8](d)
        var i = 0, out: [Int: Data] = [:]
        func readVarint() -> UInt64? {
            var shift: UInt64 = 0, v: UInt64 = 0
            while i < b.count {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: _ = readVarint()
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return out }
                out[field] = Data(b[i ..< i + Int(len)])
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}
