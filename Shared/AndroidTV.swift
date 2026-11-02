import Foundation
import Network
import Security
import AndroidTVRemoteControl

/// Google/Android TV Remote Service v2. This is deliberately independent of Bravia.swift:
/// the Sony JSON-RPC and IRCC code must never be sent to a non-Sony television.
@MainActor
final class AndroidTVTransport {
    static let shared = AndroidTVTransport()

    private var remotes: [String: RemoteManager] = [:]
    private var ready: Set<String> = []
    private var connectWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var pairings: [String: PairingManager] = [:]
    private var pairStartWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var pairFinishWaiters: [String: CheckedContinuation<Void, Error>] = [:]

    private init() {}

    /// Initiates the system TV's on-screen six-character pairing challenge.
    func startPairing(host: String) async throws {
        let (tls, crypto) = try makeTLS()
        let pairing = PairingManager(tls, crypto)
        pairings[host]?.disconnect()
        pairings[host] = pairing
        pairing.stateChanged = { [weak self] state in
            Task { @MainActor [weak self] in self?.pairingChanged(host: host, state: state) }
        }
        pairing.connect(host, "Obsidian", "com.google.android.tv.remote.service", timeout: 12)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pairStartWaiters[host] = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let waiting = self.pairStartWaiters.removeValue(forKey: host) {
                    waiting.resume(throwing: AppError("Android TV didn't display a pairing code. Check that Android TV Remote Service is enabled and the TV is on the same network."))
                }
            }
        }
    }

    func finishPairing(host: String, code: String) async throws {
        guard let pairing = pairings[host] else { throw AppError("Start pairing with this TV again.") }
        let pin = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard pin.count == 6, pin.allSatisfy({ $0.isHexDigit }) else {
            throw AppError("Enter the six-character code displayed on the TV (0-9 and A-F).")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pairFinishWaiters[host] = c
            pairing.sendSecret(pin)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let waiting = self.pairFinishWaiters.removeValue(forKey: host) {
                    waiting.resume(throwing: AppError("The pairing confirmation timed out. Try pairing again."))
                }
            }
        }
    }

    private func pairingChanged(host: String, state: PairingManager.PairingState) {
        switch state {
        case .waitingCode:
            pairStartWaiters.removeValue(forKey: host)?.resume()
        case .successPaired:
            pairFinishWaiters.removeValue(forKey: host)?.resume()
            pairings[host] = nil
        case .error(let error):
            let problem = AppError("Android TV pairing failed: \(error.localizedDescription)")
            pairStartWaiters.removeValue(forKey: host)?.resume(throwing: problem)
            pairFinishWaiters.removeValue(forKey: host)?.resume(throwing: problem)
        default: break
        }
    }

    func connected(host: String) -> Bool { ready.contains(host) }

    func connect(host: String) async throws {
        if ready.contains(host) { return }
        if connectWaiters[host] != nil {
            // Another action is already opening this session. Wait for its result, not a second TLS handshake.
            for _ in 0..<30 {
                if ready.contains(host) { return }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            throw AppError("Android TV remote connection timed out.")
        }
        let (tls, _) = try makeTLS()
        let remote = RemoteManager(tls, .init("iPhone", "Obsidian", "1", "Obsidian", "1"))
        remotes[host]?.disconnect()
        remotes[host] = remote
        remote.stateChanged = { [weak self] state in
            Task { @MainActor [weak self] in self?.remoteChanged(host: host, state: state) }
        }
        remote.connect(host, timeout: 10)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiters[host] = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if let waiting = self.connectWaiters.removeValue(forKey: host) {
                    waiting.resume(throwing: AppError("Could not connect to Android TV Remote Service on \(host). If this TV hasn't been paired, select Pair in Obsidian first."))
                }
            }
        }
    }

    private func remoteChanged(host: String, state: RemoteManager.RemoteState) {
        switch state {
        case .paired:
            ready.insert(host)
            connectWaiters.removeValue(forKey: host)?.resume()
        case .error(let error):
            ready.remove(host)
            connectWaiters.removeValue(forKey: host)?.resume(throwing: AppError("Android TV connection: \(error.localizedDescription)"))
        default: break
        }
    }

    func send(_ action: TVAction, host: String, known: TVState) async throws {
        try await connect(host: host)
        guard let remote = remotes[host] else { throw AppError("No Android TV remote connection.") }

        func key(_ code: UInt, times: Int = 1) {
            guard let key = AndroidTVRemoteControl.Key(rawValue: code) else { return }
            for _ in 0..<max(1, min(times, 30)) { remote.send(KeyPress(key)) }
        }

        switch action {
        case .power(let on):
            key(on == true ? 224 : on == false ? 223 : 26)
        case .volumeUp(let n): key(24, times: n)
        case .volumeDown(let n): key(25, times: n)
        case .mute(let on):
            if on == nil || known.muted != on { key(164) }
        case .setVolume(let level):
            guard let current = known.volume else { throw AppError("Exact volume isn't available for this TV yet. Use volume up/down.") }
            if level > current { key(24, times: level - current) }
            if level < current { key(25, times: current - level) }
        case .key(let name):
            guard let code = Self.androidKey(name) else { throw AppError("\(Keys.label(name)) is a Sony-only button on this TV.") }
            key(code)
        case .input(let input):
            let value = input.lowercased()
            if let port = (1...4).first(where: { value.contains("hdmi\($0)") || value.contains("hdmi \($0)") || value.contains("port=\($0)") }) {
                key(UInt(242 + port))
            } else { key(178) }
        case .app(let app):
            if app.hasPrefix("side:") {
                try await SideApps.launch(host, String(app.dropFirst(5)))
            } else if let url = Self.deepLink(app) {
                remote.send(DeepLink(url))
            } else {
                throw AppError("Add this app from ADB, or choose a supported Android TV app shortcut.")
            }
        case .screen:
            throw AppError("Picture-off is a Sony-specific feature. This TV may offer it through its own settings.")
        case .text(let input):
            for ch in input.lowercased() {
                guard let code = Self.characterKey(ch) else { throw AppError("Android TV text input currently supports letters, numbers and spaces.") }
                key(code)
            }
        }
    }

    static func supportsKey(_ name: String) -> Bool { androidKey(name) != nil }

    private static func androidKey(_ name: String) -> UInt? {
        let map: [String: UInt] = [
            "Up": 19, "Down": 20, "Left": 21, "Right": 22, "Confirm": 23, "Enter": 23,
            "Home": 3, "Return": 4, "Back": 4, "Options": 82, "ActionMenu": 82,
            "VolumeUp": 24, "VolumeDown": 25, "Mute": 164, "TvPower": 26,
            "WakeUp": 224, "PowerOff": 223, "Tv": 170, "Input": 178,
            "ChannelUp": 166, "ChannelDown": 167, "Guide": 172, "Info": 165,
            "Play": 126, "Pause": 127, "Stop": 86, "PlayPause": 85,
            "Next": 87, "Prev": 88, "Forward": 90, "Rewind": 89,
            "Settings": 176, "Help": 259, "SubTitle": 175, "ClosedCaption": 175,
            "Red": 183, "Green": 184, "Yellow": 185, "Blue": 186,
            "Hdmi1": 243, "Hdmi2": 244, "Hdmi3": 245, "Hdmi4": 246,
            "Num0": 7, "Num1": 8, "Num2": 9, "Num3": 10, "Num4": 11,
            "Num5": 12, "Num6": 13, "Num7": 14, "Num8": 15, "Num9": 16,
        ]
        return map[name] ?? map.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private static func characterKey(_ c: Character) -> UInt? {
        if c == " " { return 62 }
        if let a = c.asciiValue {
            if (97...122).contains(a) { return UInt(a - 97 + 29) }
            if (48...57).contains(a) { return UInt(a - 48 + 7) }
        }
        return nil
    }

    private static func deepLink(_ app: String) -> String? {
        if app.contains("://") { return app }
        let name = app.lowercased()
        if name.contains("youtube") { return "https://www.youtube.com" }
        if name.contains("netflix") { return "https://www.netflix.com" }
        if name.contains("spotify") { return "https://open.spotify.com" }
        if name.contains("prime") { return "https://www.primevideo.com" }
        return nil
    }

    private func makeTLS() throws -> (TLSManager, CryptoManager) {
        let identity = try AndroidTVIdentity.loadOrCreate()
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess,
              let cert, let clientKey = SecCertificateCopyKey(cert) else {
            throw AppError("Couldn't read the Android TV client certificate.")
        }
        let server = ServerPublicKey()
        let crypto = CryptoManager()
        crypto.clientPublicCertificate = { .Result(clientKey) }
        crypto.serverPublicCertificate = {
            if let key = server.read() { return .Result(key) }
            return .Error(.noServerPublicCertificate)
        }
        let tls = TLSManager { .Result([[kSecImportItemIdentity as String: identity]] as CFArray) }
        tls.secTrustClosure = { trust in
            if let key = SecTrustCopyKey(trust) { server.save(key) }
        }
        return (tls, crypto)
    }
}

private final class ServerPublicKey {
    private let lock = NSLock()
    private var key: SecKey?
    func save(_ value: SecKey) { lock.lock(); key = value; lock.unlock() }
    func read() -> SecKey? { lock.lock(); defer { lock.unlock() }; return key }
}

/// Locally generated per-installation RSA identity. Nothing is checked into GitHub.
/// The key and its certificate live in the app's iOS Keychain.
private enum AndroidTVIdentity {
    private static let keyTag = Data("com.soum91.phosphor.androidtv".utf8)
    private static let certificateLabel = "Obsidian Android TV"

    static func loadOrCreate() throws -> SecIdentity {
        // Prefer the identity we previously paired with. Never rotate a paired key
        // just because the app was upgraded or the TV is temporarily unreachable.
        if let saved = findIdentity(label: certificateLabel) { return saved }
        if let legacy = findIdentity(label: nil) { return legacy }

        // 1.1.0.18 generated a persistent key but added its certificate as raw
        // bytes. On some iOS keychains this does not create the certificate's
        // public-key hash, so no kSecClassIdentity item can be formed. Reuse the
        // existing private key and import a corrected certificate by reference.
        let privateKey = try existingOrNewKey()
        let certificate = try makeCertificate(privateKey: privateKey)
        let add: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: certificateLabel
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw AppError("Couldn't save Android TV certificate (Keychain error \(status)).")
        }

        if let saved = findIdentity(label: certificateLabel) { return saved }
        if let saved = findIdentity(label: nil) { return saved }

        // Include the actual keychain attributes in the error rather than making
        // the user check their Wi-Fi when the failure happened entirely on iOS.
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyTag,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var keyAttrs: CFTypeRef?
        var certAttrs: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyAttrs)
        let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &certAttrs)
        let keyHash = (keyAttrs as? [String: Any])?[kSecAttrApplicationLabel as String] as? Data
        let certHash = (certAttrs as? [String: Any])?[kSecAttrPublicKeyHash as String] as? Data
        if let keyHash, let certHash, keyHash != certHash {
            throw AppError("iOS Keychain saved the Android TV key and certificate with different public-key hashes. Please report this pairing error.")
        }
        throw AppError("iOS couldn't assemble the Android TV identity (key \(keyStatus), certificate \(certStatus)). Please report this pairing error.")
    }

    private static func findIdentity(label: String?) -> SecIdentity? {
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity,
                                      kSecMatchLimit: kSecMatchLimitOne,
                                      kSecReturnRef: true]
        var filtered = query
        if let label { filtered[kSecAttrLabel] = label }
        var saved: CFTypeRef?
        guard SecItemCopyMatching(filtered as CFDictionary, &saved) == errSecSuccess,
              let saved, CFGetTypeID(saved) == SecIdentityGetTypeID() else { return nil }
        let identity = saved as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess,
              let cert,
              (SecCertificateCopySubjectSummary(cert) as String?) == "Obsidian Remote" else { return nil }
        return identity
    }

    private static func existingOrNewKey() throws -> SecKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var existing: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &existing)
        if found == errSecSuccess, let existing,
           CFGetTypeID(existing) == SecKeyGetTypeID() { return existing as! SecKey }
        guard found == errSecItemNotFound else {
            throw AppError("Couldn't read Android TV private key (Keychain error \(found)).")
        }
        let options: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true,
                                  kSecAttrApplicationTag: keyTag]
        ]
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(options as CFDictionary, &err) else {
            throw AppError("Couldn't generate an Android TV pairing identity.")
        }
        return privateKey
    }

    private static func makeCertificate(privateKey: SecKey) throws -> SecCertificate {
        var err: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            throw AppError("Couldn't read the Android TV public key.")
        }

        let signatureAlgorithm = asn1(0x30, oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b]) + asn1(0x05, Data()))
        let rsaAlgorithm = asn1(0x30, oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01]) + asn1(0x05, Data()))
        let name = asn1(0x30, asn1(0x31, asn1(0x30, oid([0x55,0x04,0x03]) + asn1(0x0c, Data("Obsidian Remote".utf8)))))
        var serial = Data(count: 16)
        let randomStatus = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw AppError("Couldn't generate a certificate serial number.") }
        serial[0] &= 0x7f
        let until = Date().addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let validity = asn1(0x30, time(Date().addingTimeInterval(-86400)) + time(until))
        let spki = asn1(0x30, rsaAlgorithm + asn1(0x03, Data([0]) + pkcs1))
        let body = asn1(0x30, asn1(0xa0, integer(Data([2]))) + integer(serial) + signatureAlgorithm + name + validity + name + spki)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, &err) as Data? else {
            throw AppError("Couldn't sign the Android TV certificate.")
        }
        let certificate = asn1(0x30, body + signatureAlgorithm + asn1(0x03, Data([0]) + signature))
        guard let secCertificate = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw AppError("Couldn't create an Android TV certificate.")
        }
        return secCertificate
    }

    private static func oid(_ b: [UInt8]) -> Data { asn1(0x06, Data(b)) }
    private static func integer(_ b: Data) -> Data { asn1(0x02, b.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + b : b) }
    private static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return asn1(0x18, Data(formatter.string(from: date).utf8))
    }
    private static func asn1(_ type: UInt8, _ content: Data) -> Data {
        var result = Data([type])
        if content.count < 128 { result.append(UInt8(content.count)) }
        else if content.count < 256 { result.append(contentsOf: [0x81, UInt8(content.count)]) }
        else { result.append(contentsOf: [0x82, UInt8((content.count >> 8) & 0xff), UInt8(content.count & 0xff)]) }
        result.append(content)
        return result
    }
}
