import Foundation
import CryptoKit

/// Talks to Tuya's Smart Life "device sharing" cloud, the same one Home Assistant's built-in
/// Tuya integration uses. No Tuya developer account needed: you log in by scanning a QR in Smart Life.
enum TuyaConst {
    static let clientID = "HA_3y9q4ak7g4ephrvke"
    static let schema = "haauthorize"
    static let loginHost = "https://apigw.iotbing.com"
    static let qrPrefix = "tuyaSmart--qrLogin?token="
}

struct TuyaError: LocalizedError {
    let message: String
    var code: String? = nil
    var isAuth: Bool = false
    var errorDescription: String? { message }
}

struct TuyaToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var uid: String
    var expiresAt: Date
    var endpoint: String
    var userCode: String
    var terminalId: String
}

// MARK: - Crypto (port of tuya_sharing.customerapi)

enum TuyaCrypto {
    private static let nonceChars = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678")

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ s: String) -> String {
        hex(Insecure.MD5.hash(data: Data(s.utf8)))
    }

    static func hmacHex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return hex(mac)
    }

    /// 16-char AES key derived from the request id and the hash key (sid is always empty here).
    static func secret(rid: String, hashKey: String) -> String {
        String(hmacHex(key: rid, message: hashKey).prefix(16))
    }

    static func encrypt(_ plain: String, secret: String) throws -> String {
        let nonceString = String((0..<12).map { _ in nonceChars.randomElement()! })
        let nonceData = Data(nonceString.utf8)
        let box = try AES.GCM.seal(Data(plain.utf8),
                                   using: SymmetricKey(data: Data(secret.utf8)),
                                   nonce: AES.GCM.Nonce(data: nonceData))
        var sealed = Data(box.ciphertext)
        sealed.append(Data(box.tag))
        return nonceData.base64EncodedString() + sealed.base64EncodedString()
    }

    static func decrypt(_ b64: String, secret: String) throws -> Data {
        guard let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), raw.count > 28 else {
            throw TuyaError(message: "Couldn't decode the server response.")
        }
        let bytes = [UInt8](raw)
        let nonce = try AES.GCM.Nonce(data: Data(bytes[0..<12]))
        let ciphertext = Data(bytes[12..<(bytes.count - 16)])
        let tag = Data(bytes[(bytes.count - 16)...])
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: Data(secret.utf8)))
    }

    static func compactJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - QR login (unsigned endpoints)

enum TuyaLogin {
    private static func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaError(message: "Unexpected response from Tuya.")
        }
        return obj
    }

    /// Returns the QR token to show. The user scans "tuyaSmart--qrLogin?token=<token>" in Smart Life.
    static func requestQR(userCode: String) async throws -> String {
        let uc = TuyaCrypto.formEncode(userCode)
        let url = URL(string: "\(TuyaConst.loginHost)/v1.0/m/life/home-assistant/qrcode/tokens?clientid=\(TuyaConst.clientID)&usercode=\(uc)&schema=\(TuyaConst.schema)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let obj = try await json(req)
        if obj["success"] as? Bool == true,
           let result = obj["result"] as? [String: Any],
           let qr = result["qrcode"] as? String {
            return qr
        }
        throw TuyaError(message: (obj["msg"] as? String) ?? "Tuya rejected that user code.",
                        code: obj["code"].map { "\($0)" })
    }

    /// Nil while the QR hasn't been confirmed in Smart Life yet.
    static func poll(qr: String, userCode: String) async throws -> TuyaToken? {
        let uc = TuyaCrypto.formEncode(userCode)
        let url = URL(string: "\(TuyaConst.loginHost)/v1.0/m/life/home-assistant/qrcode/tokens/\(qr)?clientid=\(TuyaConst.clientID)&usercode=\(uc)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let obj = try await json(req)
        guard obj["success"] as? Bool == true, let r = obj["result"] as? [String: Any] else { return nil }
        let t = (obj["t"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        let expire = (r["expire_time"] as? NSNumber)?.doubleValue ?? 7200
        guard let access = r["access_token"] as? String,
              let refresh = r["refresh_token"] as? String,
              let endpoint = r["endpoint"] as? String else {
            throw TuyaError(message: "Login response was missing fields.")
        }
        return TuyaToken(accessToken: access,
                         refreshToken: refresh,
                         uid: "\(r["uid"] ?? "")",
                         expiresAt: Date(timeIntervalSince1970: t / 1000 + expire),
                         endpoint: endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint,
                         userCode: userCode,
                         terminalId: "\(r["terminal_id"] ?? "")")
    }
}

// MARK: - Signed API client

actor TuyaClient {
    private(set) var token: TuyaToken

    init(token: TuyaToken) { self.token = token }

    // MARK: High-level calls

    func homeIDs() async throws -> [String] {
        let result = try await request("GET", "/v1.0/m/life/users/homes")
        guard let list = result as? [[String: Any]] else { return [] }
        return list.compactMap { h in h["ownerId"].map { "\($0)" } }
    }

    func devices(homeID: String) async throws -> [DeviceInfo] {
        let result = try await request("GET", "/v1.0/m/life/ha/home/devices", query: ["homeId": homeID])
        return (result as? [[String: Any]] ?? []).compactMap(DeviceInfo.parse)
    }

    func allDevices() async throws -> [DeviceInfo] {
        var out: [DeviceInfo] = []
        for home in try await homeIDs() {
            for d in try await devices(homeID: home) where !out.contains(where: { $0.id == d.id }) {
                out.append(d)
            }
        }
        return out
    }

    // MARK: Plumbing

    func request(_ method: String, _ path: String, query: [String: Any]? = nil, body: [String: Any]? = nil) async throws -> Any? {
        try await refreshIfNeeded()
        return try await raw(method, path, query: query, body: body).result
    }

    private func refreshIfNeeded() async throws {
        guard token.expiresAt.timeIntervalSinceNow < 60 else { return }
        // The widget or a background run may already have refreshed it.
        if let stored = TokenStore.load(), stored.refreshToken != token.refreshToken || stored.expiresAt > token.expiresAt {
            token = stored
            if token.expiresAt.timeIntervalSinceNow >= 60 { return }
        }
        let response: (result: Any?, t: Double?)
        do {
            response = try await raw("GET", "/v1.0/m/token/\(token.refreshToken)")
        } catch let e as TuyaError {
            throw TuyaError(message: "Your Smart Life session expired. Sign in again. (\(e.message))", code: e.code, isAuth: true)
        }
        guard let r = response.result as? [String: Any],
              let access = r["accessToken"] as? String,
              let refresh = r["refreshToken"] as? String else {
            throw TuyaError(message: "Your Smart Life session expired. Sign in again.", isAuth: true)
        }
        let t = response.t ?? Date().timeIntervalSince1970 * 1000
        let expire = (r["expireTime"] as? NSNumber)?.doubleValue ?? 7200
        token.accessToken = access
        token.refreshToken = refresh
        if let uid = r["uid"] { token.uid = "\(uid)" }
        token.expiresAt = Date(timeIntervalSince1970: t / 1000 + expire)
        TokenStore.save(token)
    }

    private func raw(_ method: String, _ path: String, query: [String: Any]? = nil, body: [String: Any]? = nil) async throws -> (result: Any?, t: Double?) {
        let rid = UUID().uuidString.lowercased()
        let hashKey = TuyaCrypto.md5Hex(rid + token.refreshToken)
        let secret = TuyaCrypto.secret(rid: rid, hashKey: hashKey)

        var queryEnc = ""
        if let query, !query.isEmpty { queryEnc = try TuyaCrypto.encrypt(TuyaCrypto.compactJSON(query), secret: secret) }
        var bodyEnc = ""
        if let body, !body.isEmpty { bodyEnc = try TuyaCrypto.encrypt(TuyaCrypto.compactJSON(body), secret: secret) }

        let time = String(Int64(Date().timeIntervalSince1970 * 1000))
        let headers: [(String, String)] = [
            ("X-appKey", TuyaConst.clientID),
            ("X-requestId", rid),
            ("X-sid", ""),
            ("X-time", time),
            ("X-token", token.accessToken),
        ]
        let signBase = headers.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "||") + queryEnc + bodyEnc
        let sign = TuyaCrypto.hmacHex(key: hashKey, message: signBase)

        var urlString = token.endpoint + path
        if !queryEnc.isEmpty { urlString += "?encdata=" + TuyaCrypto.formEncode(queryEnc) }
        guard let url = URL(string: urlString) else { throw TuyaError(message: "Bad URL \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        for (k, v) in headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(sign, forHTTPHeaderField: "X-sign")
        if !bodyEnc.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["encdata": bodyEnc])
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TuyaError(message: "Tuya returned HTTP \(http.statusCode).", isAuth: http.statusCode == 401)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaError(message: "Unexpected response from Tuya.")
        }
        let t = (obj["t"] as? NSNumber)?.doubleValue
        guard obj["success"] as? Bool == true else {
            let code = obj["code"].map { "\($0)" }
            let msg = (obj["msg"] as? String) ?? "Request failed"
            // 1010 / 1011: token invalid or expired.
            let auth = ["1010", "1011", "1012"].contains(code ?? "")
            throw TuyaError(message: "\(msg) (\(code ?? "?"))", code: code, isAuth: auth)
        }
        guard let enc = obj["result"] as? String else { return (obj["result"], t) }
        let plain = try TuyaCrypto.decrypt(enc, secret: secret)
        if let parsed = try? JSONSerialization.jsonObject(with: plain, options: [.fragmentsAllowed]) {
            return (parsed, t)
        }
        return (String(data: plain, encoding: .utf8), t)
    }
}
