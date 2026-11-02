import SwiftUI
import CryptoKit
import Security

/// TV companion credentials are per IP and only stored in this iPhone's Keychain.
/// An existing Sony/Android TV pairing is independent and remains unchanged.
enum LiveViewSecret {
    private static let service = "com.soum91.phosphor.liveview"

    static func isLocalIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".").compactMap { UInt8($0) }
        guard pieces.count == 4 else { return false }
        return pieces[0] == 10 || (pieces[0] == 172 && (16...31).contains(pieces[1]))
            || (pieces[0] == 192 && pieces[1] == 168)
    }

    static func decode(_ base64url: String) -> Data? {
        let normalized = base64url.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), decoded.count == 32 else { return nil }
        return decoded
    }

    static func save(_ secret: Data, host: String) -> Bool {
        guard isLocalIPv4(host), secret.count == 32 else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: secret] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var newItem = query
        newItem[kSecValueData] = secret
        newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    static func load(host: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
}

@MainActor
final class LiveViewClient: ObservableObject {
    @Published var image: UIImage?
    @Published var message = "Open Obsidian TV Companion on the TV and scan its QR with your iPhone Camera."
    @Published var connected = false
    @Published var usingRelay = false

    private let session: URLSession

    init() {
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 4
        options.timeoutIntervalForResource = 4
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: options)
    }

    func watch(host: String) async {
        image = nil
        connected = false
        usingRelay = false
        guard LiveViewSecret.isLocalIPv4(host), let secret = LiveViewSecret.load(host: host) else {
            message = "Pair Live View first. Open Obsidian TV Companion on this TV, then scan its QR with the iPhone Camera."
            return
        }
        guard let url = URL(string: "http://\(host):8765/frame") else { return }
        let key = SymmetricKey(data: secret)
        var retryLANAfter = Date.distantPast
        while !Task.isCancelled {
            do {
                let clear: Data
                if Date() >= retryLANAfter {
                    do {
                        clear = try await localFrame(url: url, key: key)
                        usingRelay = false
                    } catch {
                        // Cellular, VPN and other networks may not route to the TV's LAN address.
                        retryLANAfter = Date().addingTimeInterval(30)
                        usingRelay = true
                        clear = try await ObsidianRelay.shared.request(host: host, secret: secret, action: "frame")
                    }
                } else {
                    usingRelay = true
                    clear = try await ObsidianRelay.shared.request(host: host, secret: secret, action: "frame")
                }
                guard let frame = UIImage(data: clear) else { throw LiveViewError("TV sent an unreadable frame.") }
                image = frame
                connected = true
                message = usingRelay ? "Encrypted internet preview · \(host) · Reduced frame rate"
                    : "Live from \(host) · Local network"
                if usingRelay {
                    try await Task.sleep(for: .milliseconds(1500))
                } else {
                    try await Task.sleep(for: .milliseconds(180))
                }
            } catch is CancellationError {
                break
            } catch {
                connected = false
                message = "TV isn't answering: \(error.localizedDescription). Approve screen sharing on the TV."
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func localFrame(url: URL, key: SymmetricKey) async throws -> Data {
        let time = String(Int(Date().timeIntervalSince1970))
        var nonceBytes = Data(count: 16)
        let randomResult = nonceBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomResult == errSecSuccess else { throw LiveViewError("Couldn't generate request nonce.") }
        let nonce = nonceBytes.base64URLEncodedString()
        let signed = Data("GET\n/frame\n\(time)\n\(nonce)".utf8)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: signed, using: key)).base64URLEncodedString()
        var request = URLRequest(url: url)
        request.setValue(time, forHTTPHeaderField: "X-Obsidian-Time")
        request.setValue(nonce, forHTTPHeaderField: "X-Obsidian-Nonce")
        request.setValue(mac, forHTTPHeaderField: "X-Obsidian-Mac")
        let (encrypted, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveViewError("Unexpected TV response.") }
        guard http.statusCode == 200 else { throw LiveViewError("Local screen capture HTTP \(http.statusCode)") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
    }

    func command(_ key: String, host: String) async {
        guard let secret = LiveViewSecret.load(host: host) else { return }
        do {
            _ = try await ObsidianRelay.shared.request(host: host, secret: secret,
                                                       action: "command", command: key)
        } catch {
            message = "Remote button: \(error.localizedDescription)"
        }
    }
}

private struct LiveViewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal MQTT 3.1.1 over WSS, based on Keystone's relay pattern. The shared
/// broker sees only AES-256-GCM ciphertext; each TV has its own Keychain secret.
/// Intended for limited remote preview and buttons, not continuous video.
private actor ObsidianRelay {
    static let shared = ObsidianRelay()
    private let broker = URL(string: "wss://broker.emqx.io:8084/mqtt")!
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var deviceID: String?
    private var incoming = Data()
    private var connecting: Task<Void, Error>?
    private var receiver: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<(Int, String), Error>] = [:]
    private var key: SymmetricKey?

    func request(host: String, secret: Data, action: String, command: String? = nil) async throws -> Data {
        guard secret.count == 32, LiveViewSecret.isLocalIPv4(host) else {
            throw LiveViewError("Pair this TV locally first.")
        }
        let id = Self.identity(secret)
        try await ensureConnected(id: id, secret: secret)
        guard let key else { throw LiveViewError("Relay key missing.") }
        let requestID = UUID().uuidString
        var object: [String: Any] = [
            "i": requestID, "t": Int(Date().timeIntervalSince1970), "a": action
        ]
        if let command { object["k"] = command }
        let plain = try JSONSerialization.data(withJSONObject: object)
        let encrypted = try AES.GCM.seal(plain, using: key).combined!.base64EncodedData()
        let packet = Self.publish(topic: "obsidian/\(id)/req", payload: encrypted)
        let (status, body) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int, String), Error>) in
            pending[requestID] = continuation
            Task {
                do {
                    guard let socket = self.socket else { throw LiveViewError("Relay offline.") }
                    try await socket.send(.data(packet))
                } catch {
                    self.fail(requestID, error)
                }
                try? await Task.sleep(for: .seconds(12))
                self.fail(requestID, LiveViewError("No response over the internet relay."))
            }
        }
        guard status == 200 else { throw LiveViewError(body.isEmpty ? "TV returned \(status)" : body) }
        if action == "frame" {
            guard let jpeg = Data(base64Encoded: body), !jpeg.isEmpty else {
                throw LiveViewError("Invalid encrypted TV preview.")
            }
            return jpeg
        }
        return Data(body.utf8)
    }

    private static func identity(_ secret: Data) -> String {
        SHA256.hash(data: secret).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func ensureConnected(id: String, secret: Data) async throws {
        if deviceID == id, socket != nil { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect(id: id, secret: secret) }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connect(id: String, secret: Data) async throws {
        disconnect()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        self.session = session
        let socket = session.webSocketTask(with: broker, protocols: ["mqtt"])
        self.socket = socket
        socket.resume()
        do {
            try await socket.send(.data(Self.connectPacket("ob-ip-" + String(UUID().uuidString.prefix(12)))))
            let hello = try await socket.receive()
            let bytes: Data
            switch hello {
            case .data(let data): bytes = data
            case .string(let string): bytes = Data(string.utf8)
            @unknown default: throw LiveViewError("Invalid broker handshake.")
            }
            guard bytes.count >= 4, bytes[0] == 0x20, bytes[1] == 0x02,
                  bytes[3] == 0 else { throw LiveViewError("MQTT broker refused connection.") }
            try await socket.send(.data(Self.subscribe(topic: "obsidian/\(id)/res")))
            self.key = SymmetricKey(data: secret)
            self.deviceID = id
            self.receiver = Task { await self.receiveLoop(socket) }
            self.pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { return }
                    try? await socket.send(.data(Data([0xC0, 0x00])))
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    private func disconnect() {
        receiver?.cancel()
        pinger?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        deviceID = nil
        key = nil
        incoming.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: LiveViewError("Relay changed.")) }
        pending.removeAll()
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop(_ activeSocket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await activeSocket.receive()
                let bytes: Data
                switch message {
                case .data(let data): bytes = data
                case .string(let string): bytes = Data(string.utf8)
                @unknown default: continue
                }
                incoming.append(bytes)
                while let packet = Self.nextPacket(incoming) {
                    incoming.removeFirst(packet.2)
                    if packet.0 >> 4 == 3 { handlePublish(packet.0, packet.1) }
                }
            } catch {
                if activeSocket === socket { disconnect() }
                return
            }
        }
    }

    private func handlePublish(_ type: UInt8, _ body: Data) {
        let bytes = [UInt8](body)
        guard bytes.count >= 2 else { return }
        let length = Int(bytes[0]) * 256 + Int(bytes[1])
        var start = 2 + length
        if (type >> 1) & 3 != 0 { start += 2 }
        guard start <= bytes.count, let key,
              let sealed = Data(base64Encoded: Data(bytes[start...])),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: key),
              let value = try? JSONSerialization.jsonObject(with: clear) as? [String: Any],
              let id = value["i"] as? String else { return }
        let code = value["c"] as? Int ?? 500
        let body = value["b"] as? String ?? ""
        pending.removeValue(forKey: id)?.resume(returning: (code, body))
    }

    private static func mqttString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)]) + bytes
    }

    private static func size(_ length: Int) -> Data {
        var value = length
        var output = Data()
        repeat {
            var next = UInt8(value % 128)
            value /= 128
            if value > 0 { next |= 0x80 }
            output.append(next)
        } while value > 0
        return output
    }

    private static func connectPacket(_ id: String) -> Data {
        mqtt(Data([0x10]), mqttString("MQTT") + Data([0x04, 0x02, 0x00, 0x3c]) + mqttString(id))
    }

    private static func subscribe(topic: String) -> Data {
        mqtt(Data([0x82]), Data([0, 1]) + mqttString(topic) + Data([0]))
    }

    private static func publish(topic: String, payload: Data) -> Data {
        mqtt(Data([0x30]), mqttString(topic) + payload)
    }

    private static func mqtt(_ header: Data, _ body: Data) -> Data {
        header + size(body.count) + body
    }

    private static func nextPacket(_ data: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        var multiplier = 1, length = 0, offset = 1
        while true {
            guard offset < bytes.count, offset < 5 else { return nil }
            length += Int(bytes[offset] & 0x7f) * multiplier
            multiplier *= 128
            if bytes[offset] & 0x80 == 0 { break }
            offset += 1
        }
        let begin = offset + 1
        guard length <= 200_000, bytes.count >= begin + length else { return nil }
        return (bytes[0], Data(bytes[begin..<(begin + length)]), begin + length)
    }
}

struct LiveView: View {
    @EnvironmentObject var store: Store
    @StateObject private var client = LiveViewClient()
    @State private var retry = 0
    let pairingVersion: Int

    var body: some View {
        ZStack {
            Theme.background(Theme.accent, strength: 0.14)
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.tv.name).font(.title2.bold())
                            Text(client.usingRelay ? "Live View · internet preview" : "Live View · local network")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(client.connected ? "Live" : "Offline", systemImage: "circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(client.connected ? .green : .secondary)
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 15).fill(.black)
                        if let image = client.image {
                            Image(uiImage: image)
                                .resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 15))
                        } else {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 42)).foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)

                    Text(client.message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Reconnect") { retry += 1 }
                        .buttonStyle(.bordered).tint(Theme.accent)

                    HStack(spacing: 24) {
                        action("house.fill", "Home") { command("home") { store.perform(.key("Home")) } }
                        action("arrow.uturn.backward", "Back") { command("back") { store.perform(.key("Return")) } }
                        action("speaker.minus.fill", "Quieter") { command("volume_down") { store.perform(.volumeDown(1)) } }
                        action("speaker.plus.fill", "Louder") { command("volume_up") { store.perform(.volumeUp(1)) } }
                    }
                    VStack(spacing: 10) {
                        action("chevron.up", "Up") { command("up") { store.perform(.key("Up")) } }
                        HStack(spacing: 48) {
                            action("chevron.left", "Left") { command("left") { store.perform(.key("Left")) } }
                            action("circle.fill", "OK") { command("ok") { store.perform(.key("Confirm")) } }
                            action("chevron.right", "Right") { command("right") { store.perform(.key("Right")) } }
                        }
                        action("chevron.down", "Down") { command("down") { store.perform(.key("Down")) } }
                    }
                    .padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                    Text("Approve each screen sharing session on the TV. For internet buttons, enable Obsidian in TV Accessibility settings. Directional navigation depends on the app's accessible focus. Internet preview is a low-rate prototype, not WebRTC yet. DRM and HDMI video may be black.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .navigationTitle("Live View")
        .task(id: "\(store.tv.host)-\(retry)-\(pairingVersion)") {
            await client.watch(host: store.tv.host)
        }
    }

    private func action(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(Theme.card, in: Circle())
        }
        .accessibilityLabel(title)
    }

    private func command(_ name: String, local: @escaping () -> Void) {
        if client.usingRelay {
            Task { await client.command(name, host: store.tv.host) }
        } else {
            local()
        }
    }
}
