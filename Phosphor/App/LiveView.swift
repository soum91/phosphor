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
        guard LiveViewSecret.isLocalIPv4(host), let secret = LiveViewSecret.load(host: host) else {
            message = "Pair Live View first. Open Obsidian TV Companion on this TV, then scan its QR with the iPhone Camera."
            return
        }
        guard let url = URL(string: "http://\(host):8765/frame") else { return }
        let key = SymmetricKey(data: secret)
        while !Task.isCancelled {
            do {
                let time = String(Int(Date().timeIntervalSince1970))
                var nonceBytes = Data(count: 16)
                let randomResult = nonceBytes.withUnsafeMutableBytes {
                    SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
                }
                guard randomResult == errSecSuccess else { throw LiveViewError("Couldn't create request nonce.") }
                let nonce = nonceBytes.base64URLEncodedString()
                let signed = Data("GET\n/frame\n\(time)\n\(nonce)".utf8)
                let mac = Data(HMAC<SHA256>.authenticationCode(for: signed, using: key)).base64URLEncodedString()
                var request = URLRequest(url: url)
                request.setValue(time, forHTTPHeaderField: "X-Obsidian-Time")
                request.setValue(nonce, forHTTPHeaderField: "X-Obsidian-Nonce")
                request.setValue(mac, forHTTPHeaderField: "X-Obsidian-Mac")
                let (encrypted, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LiveViewError("Unexpected TV response.") }
                guard http.statusCode == 200 else {
                    throw LiveViewError(http.statusCode == 403 ? "TV rejected Live View pairing. Scan its QR again."
                        : "TV companion is waiting for screen sharing approval (HTTP \(http.statusCode)).")
                }
                let box = try AES.GCM.SealedBox(combined: encrypted)
                let clear = try AES.GCM.open(box, using: key)
                guard let frame = UIImage(data: clear) else { throw LiveViewError("TV sent an unreadable frame.") }
                image = frame
                connected = true
                message = "Live from \(host) · Local network"
                try await Task.sleep(for: .milliseconds(180))
            } catch is CancellationError {
                break
            } catch {
                connected = false
                message = error.localizedDescription
                try? await Task.sleep(for: .seconds(2))
            }
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
                            Text("Live View · local network").font(.caption).foregroundStyle(.secondary)
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
                        action("house.fill", "Home") { store.perform(.key("Home")) }
                        action("arrow.uturn.backward", "Back") { store.perform(.key("Return")) }
                        action("speaker.minus.fill", "Quieter") { store.perform(.volumeDown(1)) }
                        action("speaker.plus.fill", "Louder") { store.perform(.volumeUp(1)) }
                    }
                    VStack(spacing: 10) {
                        action("chevron.up", "Up") { store.perform(.key("Up")) }
                        HStack(spacing: 48) {
                            action("chevron.left", "Left") { store.perform(.key("Left")) }
                            action("circle.fill", "OK") { store.perform(.key("Confirm")) }
                            action("chevron.right", "Right") { store.perform(.key("Right")) }
                        }
                        action("chevron.down", "Down") { store.perform(.key("Down")) }
                    }
                    .padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                    Text("For privacy, Android requires you to approve screen capture on the TV. Protected video and HDMI input may not appear in Live View.")
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
}
