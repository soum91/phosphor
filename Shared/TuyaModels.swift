import Foundation

struct DeviceInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var category: String
    var productName: String
    var online: Bool
    var localKey: String?

    static func parse(_ d: [String: Any]) -> DeviceInfo? {
        guard let id = d["id"] as? String else { return nil }
        return DeviceInfo(id: id,
                          name: (d["name"] as? String) ?? "Device",
                          category: (d["category"] as? String) ?? "",
                          productName: (d["product_name"] as? String) ?? (d["productName"] as? String) ?? "",
                          online: (d["online"] as? Bool) ?? ((d["online"] as? NSNumber)?.boolValue ?? true),
                          localKey: (d["local_key"] as? String) ?? (d["localKey"] as? String))
    }

    /// "wnykq" is Tuya's universal remote (IR blaster) category.
    var isBlaster: Bool {
        let p = productName.lowercased()
        return category == "wnykq" || category == "wnyk" || p.contains("remote") || p.contains("ir blaster")
    }

    var hasKey: Bool { !(localKey ?? "").isEmpty }
}

enum TokenStore {
    static func load() -> TuyaToken? { AppGroup.read(TuyaToken.self, "token.json") }
    static func save(_ t: TuyaToken) { AppGroup.write(t, "token.json") }
    static func clear() { AppGroup.remove("token.json") }
}

/// Everything needed to reach the Tuya IR blaster on Wi-Fi. Same blaster Redshift uses.
struct BlasterConfig: Codable, Equatable {
    var devId: String?
    var name: String?
    var localKey: String?
    var host: String?
    var version: Double?
    /// What the blaster turned out to speak.
    var detected: IRFormat?
    /// Set by hand in Settings when detection gets it wrong.
    var forced: IRFormat?

    var hasKey: Bool { !(devId ?? "").isEmpty && !(localKey ?? "").isEmpty }
    var isReady: Bool { hasKey && !(host ?? "").isEmpty }
    var format: IRFormat { forced ?? detected ?? .classic }

    static var stored: BlasterConfig {
        get { AppGroup.read(BlasterConfig.self, "blaster.json") ?? BlasterConfig() }
        set { AppGroup.write(newValue, "blaster.json") }
    }
}
