import Foundation

/// Tuya raw IR codes are base64 of little-endian UInt16 durations in microseconds:
/// mark, space, mark, space… always ending on a mark. Same format tinytuya and Redshift use.
enum IRPulses {
    static func base64(_ pulses: [Int]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pulses.count * 2)
        for p in pulses {
            let v = UInt16(clamping: p)
            bytes.append(UInt8(v & 0xff))
            bytes.append(UInt8(v >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    static func pulses(_ code: String) -> [Int]? {
        var s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some blasters report learned codes with a leading "1".
        if s.count % 4 == 1, s.hasPrefix("1") { s.removeFirst() }
        guard let d = Data(base64Encoded: s), !d.isEmpty, d.count % 2 == 0 else { return nil }
        let b = [UInt8](d)
        return stride(from: 0, to: b.count, by: 2).map { Int(b[$0]) | (Int(b[$0 + 1]) << 8) }
    }

    /// Cleans a learned code into plain base64 the blaster can replay.
    static func normalize(_ code: String) -> String? {
        guard let p = pulses(code), p.count >= 4 else { return nil }
        return base64(p)
    }
}

/// Sony SIRC: 2400 µs header, 600 µs gaps, 1200 µs for a 1 and 600 µs for a 0, least significant bit first.
/// 7-bit command, then a 5-bit (12-bit codes), 8-bit (15-bit codes) or 5+8-bit (20-bit codes) address.
/// Sony TVs want each frame three times, one every 45 ms. Same encoder as Redshift.
enum SIRC {
    static func code(command: Int, fields: [(value: Int, bits: Int)]) -> String {
        var frame: [Int] = [2400, 600]
        func add(_ value: Int, _ bits: Int) {
            for i in 0..<bits {
                frame.append((value >> i) & 1 == 1 ? 1200 : 600)
                frame.append(600)
            }
        }
        add(command, 7)
        for f in fields { add(f.value, f.bits) }
        frame.removeLast()   // the last space becomes the gap to the next frame
        let length = frame.reduce(0, +)
        var all: [Int] = []
        for i in 0..<3 {
            all += frame
            if i < 2 { all.append(max(45_000 - length, 10_000)) }
        }
        return IRPulses.base64(all)
    }
}

/// Sony's IRCC codes (what the TV takes over Wi-Fi) are the SIRC code in a wrapper:
/// 4 bytes code length type (1 = 12-bit, 2 = 15-bit, 3 = 20-bit), 4 bytes address, 4 bytes command, then 0x03.
/// So every button the TV reports over Wi-Fi can also be sent over IR, no learning needed.
enum IRCC {
    struct Parts: Equatable { var type: Int; var address: Int; var command: Int }

    static func parts(_ code: String) -> Parts? {
        guard let d = Data(base64Encoded: code), d.count >= 12 else { return nil }
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let p = Parts(type: u32(0), address: u32(4), command: u32(8))
        guard (1...3).contains(p.type), p.command < 128 else { return nil }
        return p
    }

    static func make(type: Int, address: Int, command: Int) -> String {
        var b: [UInt8] = []
        for v in [type, address, command] {
            b += [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        b.append(0x03)
        return Data(b).base64EncodedString()
    }

    /// The same button as raw IR for the Tuya blaster.
    static func toIR(_ code: String) -> String? {
        guard let p = parts(code) else { return nil }
        switch p.type {
        case 1: return SIRC.code(command: p.command, fields: [(p.address & 0x1f, 5)])
        case 2: return SIRC.code(command: p.command, fields: [(p.address & 0xff, 8)])
        default:
            // 20-bit: 5-bit device in the high byte, 8-bit extension in the low byte.
            return SIRC.code(command: p.command, fields: [((p.address >> 8) & 0x1f, 5), (p.address & 0xff, 8)])
        }
    }
}

/// What the blaster speaks. tinytuya calls these control type 1 and 2.
enum IRFormat: String, Codable, CaseIterable, Identifiable {
    case classic, modern
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic (DP 201/202)" : "Newer (DP 1–13)" }
}

enum IRCommand {
    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func send(_ code: String, _ format: IRFormat) -> [String: JSONValue] {
        switch format {
        case .classic:
            return ["201": .string(json(["control": "send_ir", "type": 0, "head": "", "key1": "1" + code]))]
        case .modern:
            return ["1": .string("study_key"), "13": .int(0), "7": .string(code)]
        }
    }

    static func mode(_ mode: String, _ format: IRFormat) -> [String: JSONValue] {
        switch format {
        case .classic: return ["201": .string(json(["control": mode]))]
        case .modern: return ["1": .string(mode)]
        }
    }

    static func study(_ f: IRFormat) -> [String: JSONValue] { mode("study", f) }
    static func studyExit(_ f: IRFormat) -> [String: JSONValue] { mode("study_exit", f) }

    /// A learned code in a status report, and which format it came in on.
    static func learned(in dps: [String: JSONValue]) -> (code: String, format: IRFormat)? {
        for (dp, f) in [("202", IRFormat.classic), ("2", IRFormat.modern)] {
            if let s = dps[dp]?.stringValue, s.count >= 8, let clean = IRPulses.normalize(s) {
                return (clean, f)
            }
        }
        return nil
    }

    static func hint(_ dps: [String: JSONValue]) -> IRFormat? {
        if dps["201"] != nil || dps["202"] != nil { return .classic }
        if dps["1"] != nil || dps["13"] != nil { return .modern }
        return nil
    }
}

// MARK: - TV keys

enum KeyGroup: String, CaseIterable, Identifiable {
    case main = "Power and volume"
    case navigation = "Navigation"
    case playback = "Playback"
    case inputs = "Inputs"
    case apps = "Apps and assistant"
    case picture = "Picture and sound"
    case colors = "Color buttons"
    case numbers = "Numbers"
    case channels = "Channels and guide"
    case other = "More from the TV"
    var id: String { rawValue }
}

struct KeyDef: Identifiable, Hashable {
    /// Sony's own IRCC name ("VolumeUp", "Confirm"…), so it matches what the TV reports over Wi-Fi.
    let id: String
    let label: String
    let symbol: String?
    let group: KeyGroup
    /// Built-in IRCC code (Bravia remote). The TV's own list wins when it has been read.
    let ircc: String?

    init(_ id: String, _ label: String, _ symbol: String?, _ group: KeyGroup, _ ircc: String?) {
        self.id = id; self.label = label; self.symbol = symbol; self.group = group; self.ircc = ircc
    }
}

/// The Bravia remote. Codes are standard Sony ones: 12-bit on address 1, 15-bit on 0x97 / 0xA4 / 0xC4 / 0x1A.
/// Over Wi-Fi the TV's own code list (getRemoteControllerInfo) is used when it has it; over IR these are turned
/// into SIRC. Anything the TV reports that isn't here shows up under "More from the TV".
enum Keys {
    private static func k1(_ c: Int) -> String { IRCC.make(type: 1, address: 1, command: c) }
    private static func k2(_ a: Int, _ c: Int) -> String { IRCC.make(type: 2, address: a, command: c) }

    static let builtin: [KeyDef] = [
        KeyDef("TvPower", "Power", "power", .main, k1(21)),
        KeyDef("WakeUp", "Power on", "power.circle.fill", .main, k1(46)),
        KeyDef("PowerOff", "Power off", "power.circle", .main, k1(47)),
        KeyDef("VolumeUp", "Volume up", "plus", .main, k1(18)),
        KeyDef("VolumeDown", "Volume down", "minus", .main, k1(19)),
        KeyDef("Mute", "Mute", "speaker.slash.fill", .main, k1(20)),

        KeyDef("Up", "Up", "chevron.up", .navigation, k1(116)),
        KeyDef("Down", "Down", "chevron.down", .navigation, k1(117)),
        KeyDef("Left", "Left", "chevron.left", .navigation, k1(52)),
        KeyDef("Right", "Right", "chevron.right", .navigation, k1(51)),
        KeyDef("Confirm", "OK", "circle.circle", .navigation, k1(101)),
        KeyDef("Return", "Back", "arrow.uturn.backward", .navigation, k2(0x97, 35)),
        KeyDef("Home", "Home", "house.fill", .navigation, k1(96)),
        KeyDef("Options", "Options", "ellipsis", .navigation, k2(0x97, 54)),
        KeyDef("ActionMenu", "Quick settings", "gearshape.fill", .navigation, k2(0xC4, 75)),
        KeyDef("Display", "Info", "info.circle", .navigation, k1(58)),
        KeyDef("Exit", "Exit", "xmark", .navigation, k1(99)),

        KeyDef("Play", "Play", "play.fill", .playback, k2(0x97, 26)),
        KeyDef("Pause", "Pause", "pause.fill", .playback, k2(0x97, 25)),
        KeyDef("Stop", "Stop", "stop.fill", .playback, k2(0x97, 24)),
        KeyDef("Rewind", "Rewind", "backward.fill", .playback, k2(0x97, 27)),
        KeyDef("Forward", "Fast forward", "forward.fill", .playback, k2(0x97, 28)),
        KeyDef("Prev", "Previous", "backward.end.fill", .playback, k2(0x97, 60)),
        KeyDef("Next", "Next", "forward.end.fill", .playback, k2(0x97, 61)),
        KeyDef("Rec", "Record", "record.circle", .playback, k2(0x97, 32)),

        KeyDef("Input", "Input", "rectangle.portrait.and.arrow.forward", .inputs, k1(37)),
        KeyDef("Hdmi1", "HDMI 1", "1.square", .inputs, k2(0x1A, 90)),
        KeyDef("Hdmi2", "HDMI 2", "2.square", .inputs, k2(0x1A, 91)),
        KeyDef("Hdmi3", "HDMI 3", "3.square", .inputs, k2(0x1A, 92)),
        KeyDef("Hdmi4", "HDMI 4", "4.square", .inputs, k2(0x1A, 93)),

        KeyDef("Netflix", "Netflix", "n.square.fill", .apps, k2(0x1A, 124)),
        KeyDef("YouTube", "YouTube", "play.rectangle.fill", .apps, k2(0xC4, 71)),
        KeyDef("GooglePlay", "Google Play", "bag.fill", .apps, k2(0xC4, 70)),
        KeyDef("Assists", "Assistant", "mic.fill", .apps, k2(0xC4, 59)),

        KeyDef("Audio", "Audio track", "waveform", .picture, k1(23)),
        KeyDef("SubTitle", "Subtitles", "captions.bubble", .picture, k2(0x97, 40)),
        KeyDef("ClosedCaption", "Captions", "captions.bubble.fill", .picture, k2(0xA4, 16)),
        KeyDef("Wide", "Aspect", "aspectratio", .picture, k2(0xA4, 61)),
        KeyDef("PicOff", "Picture off", "tv.slash", .picture, k1(62)),

        KeyDef("Red", "Red", "circle.fill", .colors, k2(0x97, 37)),
        KeyDef("Green", "Green", "circle.fill", .colors, k2(0x97, 38)),
        KeyDef("Yellow", "Yellow", "circle.fill", .colors, k2(0x97, 39)),
        KeyDef("Blue", "Blue", "circle.fill", .colors, k2(0x97, 36)),

        KeyDef("Num1", "1", nil, .numbers, k1(0)),
        KeyDef("Num2", "2", nil, .numbers, k1(1)),
        KeyDef("Num3", "3", nil, .numbers, k1(2)),
        KeyDef("Num4", "4", nil, .numbers, k1(3)),
        KeyDef("Num5", "5", nil, .numbers, k1(4)),
        KeyDef("Num6", "6", nil, .numbers, k1(5)),
        KeyDef("Num7", "7", nil, .numbers, k1(6)),
        KeyDef("Num8", "8", nil, .numbers, k1(7)),
        KeyDef("Num9", "9", nil, .numbers, k1(8)),
        KeyDef("Num0", "0", nil, .numbers, k1(9)),
        KeyDef("DOT", "Dot", "circle.fill", .numbers, k2(0x97, 29)),
        KeyDef("Enter", "Enter", "return", .numbers, k1(11)),

        KeyDef("ChannelUp", "Channel up", "chevron.up.2", .channels, k1(16)),
        KeyDef("ChannelDown", "Channel down", "chevron.down.2", .channels, k1(17)),
        KeyDef("GGuide", "Guide", "list.bullet.rectangle", .channels, k2(0xA4, 91)),
        KeyDef("Jump", "Last channel", "arrow.uturn.left", .channels, k1(59)),
    ]

    private static let byID: [String: KeyDef] = Dictionary(builtin.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Everything: built-in keys, plus any extra the TV reports (under "More from the TV").
    static func all(remote: [String: String] = RemoteCodes.load()) -> [KeyDef] {
        let extra = remote.keys.filter { byID[$0] == nil }.sorted().map { name in
            KeyDef(name, prettify(name), nil, .other, remote[name])
        }
        return builtin + extra
    }

    static func def(_ id: String) -> KeyDef? {
        if let d = byID[id] { return d }
        let remote = RemoteCodes.load()
        if let c = remote[id] { return KeyDef(id, prettify(id), nil, .other, c) }
        return nil
    }

    static func label(_ id: String) -> String { def(id)?.label ?? prettify(id) }

    /// "ClosedCaption" → "Closed caption".
    static func prettify(_ n: String) -> String {
        let chars = Array(n)
        var out = ""
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase, chars[i - 1].isLowercase { out.append(" ") }
            out += i == 0 ? String(ch) : ch.lowercased()
        }
        return out
    }

    /// What the TV takes over Wi-Fi: its own code for the name first, then the built-in one.
    static func ircc(_ id: String, remote: [String: String] = RemoteCodes.load()) -> String? {
        remote[id] ?? byID[id]?.ircc
    }

    /// What the blaster sends: a learned code first, then the IRCC code turned into SIRC.
    static func ir(_ id: String, learned: [String: String] = LearnedCodes.load(), remote: [String: String] = RemoteCodes.load()) -> String? {
        if let l = learned[id] { return l }
        return ircc(id, remote: remote).flatMap(IRCC.toIR)
    }
}

/// The TV's own button list, read over Wi-Fi once and kept for the widget and IR.
enum RemoteCodes {
    static func load() -> [String: String] { AppGroup.read([String: String].self, "remote.json") ?? [:] }
    static func save(_ c: [String: String]) { AppGroup.write(c, "remote.json") }
}

/// Codes learned from the real remote, by key id. Shared with the widget.
enum LearnedCodes {
    static func load() -> [String: String] { AppGroup.read([String: String].self, "ircodes.json") ?? [:] }
    static func save(_ c: [String: String]) { AppGroup.write(c, "ircodes.json") }

    /// Redshift's key ids on its Sony TV template, mapped to Sony's names.
    static let redshiftNames: [String: String] = [
        "power": "TvPower", "input": "Input", "volUp": "VolumeUp", "volDown": "VolumeDown", "mute": "Mute",
        "chUp": "ChannelUp", "chDown": "ChannelDown", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
        "ok": "Confirm", "home": "Home", "back": "Return", "options": "Options", "guide": "GGuide",
        "play": "Play", "pause": "Pause", "netflix": "Netflix",
        "n1": "Num1", "n2": "Num2", "n3": "Num3", "n4": "Num4", "n5": "Num5",
        "n6": "Num6", "n7": "Num7", "n8": "Num8", "n9": "Num9", "n0": "Num0",
    ]

    /// Redshift's backup is a list of remotes with keys; take the learned codes off its TV remote.
    static func fromRedshift(_ data: Data) -> [String: String]? {
        guard let remotes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let tvs = remotes.filter { ($0["kind"] as? String) == "tv" }
        guard !tvs.isEmpty else { return nil }
        var out: [String: String] = [:]
        for r in tvs {
            for k in r["keys"] as? [[String: Any]] ?? [] {
                guard let id = k["id"] as? String, let code = k["code"] as? String, let clean = IRPulses.normalize(code) else { continue }
                out[redshiftNames[id] ?? id] = clean
            }
        }
        return out
    }
}
