import Foundation
import SwiftUI
import CoreMotion

/// Input waiting to go to the TV. Touch handling writes here directly (no async hops, so nothing reorders):
/// movement is summed, while button changes and keys are queued in order with the movement before them.
final class HIDInput: @unchecked Sendable {
    private let lock = NSLock()
    private var dx = 0, dy = 0, wheel = 0, pan = 0
    private var buttons: UInt8 = 0
    private var queue: [String] = []
    private let wake: AsyncStream<Void>.Continuation

    init(wake: AsyncStream<Void>.Continuation) { self.wake = wake }

    func move(_ x: Int, _ y: Int) { lock.lock(); dx += x; dy += y; lock.unlock(); wake.yield() }
    func scroll(_ v: Int, _ h: Int) { lock.lock(); wheel += v; pan += h; lock.unlock(); wake.yield() }

    func setButton(_ mask: UInt8, _ down: Bool) {
        lock.lock()
        flushMotion()
        if down { buttons |= mask } else { buttons &= ~mask }
        queue.append(Self.mouse(buttons, 0, 0, 0, 0))
        lock.unlock()
        wake.yield()
    }

    func click(_ mask: UInt8) {
        setButton(mask, true)
        setButton(mask, false)
    }

    func keys(_ reports: [[UInt8]]) {
        lock.lock()
        flushMotion()
        for r in reports {
            queue.append("{\"id\":\(HIDSession.keyboardID),\"command\":\"report\",\"report\":[\(r.map(String.init).joined(separator: ","))]}\n")
        }
        lock.unlock()
        wake.yield()
    }

    /// Everything waiting, as hid tool lines, oldest first.
    func take() -> String {
        lock.lock()
        flushMotion()
        let out = queue.joined()
        queue.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    /// Lets go of any held button (used when leaving).
    func releaseAll() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard buttons != 0 else { return nil }
        buttons = 0
        return Self.mouse(0, 0, 0, 0, 0)
    }

    private func flushMotion() {
        var n = 0
        while (dx != 0 || dy != 0 || wheel != 0 || pan != 0), n < 16 {
            let x = max(-127, min(127, dx)), y = max(-127, min(127, dy))
            let v = max(-127, min(127, wheel)), h = max(-127, min(127, pan))
            dx -= x; dy -= y; wheel -= v; pan -= h
            queue.append(Self.mouse(buttons, x, y, v, h))
            n += 1
        }
        if n == 16 { dx = 0; dy = 0; wheel = 0; pan = 0 }
    }

    private static func mouse(_ b: UInt8, _ x: Int, _ y: Int, _ v: Int, _ h: Int) -> String {
        func u(_ n: Int) -> Int { n < 0 ? 256 + n : n }
        return "{\"id\":\(HIDSession.mouseID),\"command\":\"report\",\"report\":[\(b),\(u(x)),\(u(y)),\(u(v)),\(u(h))]}\n"
    }
}

/// A real USB mouse and keyboard, as far as the TV can tell. Android's `hid` shell tool registers virtual HID devices
/// through /dev/uhid, so the TV shows its own pointer and handles clicks, the wheel and drags natively. We keep one
/// `hid -` process open over ADB and stream raw HID reports into it, coalescing movement so nothing queues up.
actor HIDSession {
    private let adb: ADB
    private let local: UInt32
    private let remote: UInt32
    nonisolated let input: HIDInput
    private let wakeStream: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private var drainDue = false
    private var loop: Task<Void, Never>?
    private(set) var ended = false
    private var onEnd: (@Sendable (String) -> Void)?

    static let mouseID = 1, keyboardID = 2

    /// Boot mouse with 3 buttons, X/Y, a vertical wheel and horizontal pan (AC Pan).
    static let mouseDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    ]

    /// Boot keyboard: modifiers byte, reserved byte, six key slots.
    static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
    ]

    private init(adb: ADB, local: UInt32, remote: UInt32) {
        self.adb = adb
        self.local = local
        self.remote = remote
        let (stream, cont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeStream = stream
        wake = cont
        input = HIDInput(wake: cont)
    }

    static func start(host: String, onEnd: @escaping @Sendable (String) -> Void) async throws -> HIDSession {
        let adb = ADB(host: host)
        try await adb.connect(approvalWait: 60)
        let check = try await adb.shell("ls /system/bin/hid 2>&1")
        guard check.contains("/system/bin/hid"), !check.contains("No such file") else {
            await adb.close()
            throw ADBError("This TV's firmware doesn't have Android's hid tool, so it can't take a virtual mouse.")
        }
        let ids = try await adb.openStream("exec:hid -")
        let s = HIDSession(adb: adb, local: ids.local, remote: ids.remote)
        await s.setOnEnd(onEnd)
        try await s.register()
        await s.run()
        return s
    }

    private func setOnEnd(_ f: @escaping @Sendable (String) -> Void) { onEnd = f }

    private func line(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    private func register() async throws {
        let mouse = line(["id": Self.mouseID, "command": "register", "name": "Obsidian Mouse", "vid": 0x1209, "pid": 0x0D01,
                          "bus": "usb", "descriptor": Self.mouseDescriptor.map(Int.init)])
        let kb = line(["id": Self.keyboardID, "command": "register", "name": "Obsidian Keyboard", "vid": 0x1209, "pid": 0x0D02,
                       "bus": "usb", "descriptor": Self.keyboardDescriptor.map(Int.init)])
        try await adb.write(local, remote, Array((mouse + kb).utf8))
        // Give the TV a moment to add the devices before the first report.
        try await Task.sleep(nanoseconds: 400_000_000)
        let d = try await adb.drain(local, remote)
        if d.ended {
            throw ADBError("The TV's hid tool quit: \(String(decoding: d.output, as: UTF8.self).prefix(200))")
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        wake.finish()
        if !ended {
            if let r = input.releaseAll() { try? await adb.write(local, remote, Array(r.utf8), timeout: 1) }
            await adb.closeStream(local, remote)
        }
        ended = true
        await adb.close()
    }

    // MARK: Sending

    private func tick() {
        drainDue = true
        wake.yield()
    }

    /// Wakes the moment input arrives, sends everything waiting in one write, repeats until there's nothing left.
    private func run() {
        let stream = wakeStream
        loop = Task {
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self?.tick()
                }
            }
            defer { ticker.cancel() }
            for await _ in stream {
                if Task.isCancelled || ended { return }
                do {
                    while true {
                        let text = input.take()
                        if text.isEmpty { break }
                        try await adb.write(local, remote, Array(text.utf8))
                    }
                    if drainDue {
                        drainDue = false
                        if try await adb.drain(local, remote).ended {
                            await end("The TV's hid tool stopped.")
                            return
                        }
                    }
                } catch {
                    await end(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func end(_ why: String) async {
        guard !ended else { return }
        ended = true
        await adb.close()
        onEnd?(why)
    }
}

// MARK: - Keyboard

enum HIDKeys {
    /// Report for one character on a US layout, or nil if it can't be typed.
    static func report(for ch: Character) -> [UInt8]? {
        guard let (code, shift) = usage(ch) else { return nil }
        return [shift ? 0x02 : 0, 0, code, 0, 0, 0, 0, 0]
    }

    static let release: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]

    static func tap(_ code: UInt8, shift: Bool = false) -> [[UInt8]] {
        [[shift ? 0x02 : 0, 0, code, 0, 0, 0, 0, 0], release]
    }

    static func usage(_ ch: Character) -> (UInt8, Bool)? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 97...122: return (UInt8(0x04 + a - 97), false)
        case 65...90: return (UInt8(0x04 + a - 65), true)
        case 49...57: return (UInt8(0x1E + a - 49), false)
        case 48: return (0x27, false)
        case 10, 13: return (0x28, false)
        case 9: return (0x2B, false)
        case 32: return (0x2C, false)
        default: break
        }
        let plain: [Character: UInt8] = ["-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34,
                                         "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38]
        let shifted: [Character: UInt8] = ["!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24,
                                           "*": 0x25, "(": 0x26, ")": 0x27, "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30,
                                           "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38]
        if let c = plain[ch] { return (c, false) }
        if let c = shifted[ch] { return (c, true) }
        return nil
    }

    static let enter: UInt8 = 0x28, escape: UInt8 = 0x29, backspace: UInt8 = 0x2A, tab: UInt8 = 0x2B
    static let right: UInt8 = 0x4F, left: UInt8 = 0x50, down: UInt8 = 0x51, up: UInt8 = 0x52
}

// MARK: - What the mouse page talks to

@MainActor
final class MouseLink: ObservableObject {
    enum State: Equatable {
        case off, connecting(String), ready, failed(String)
        var text: String {
            switch self {
            case .off: return "Not connected"
            case .connecting(let s): return s
            case .ready: return "Mouse connected"
            case .failed(let e): return e
            }
        }
    }

    @Published var state: State = .off
    @Published var speed = MouseLink.pref("mouseSpeed", 1.6) { didSet { UserDefaults.standard.set(speed, forKey: "mouseSpeed") } }
    @Published var accel = MouseLink.pref("mouseAccel", 0.9) { didSet { UserDefaults.standard.set(accel, forKey: "mouseAccel") } }
    @Published var airSpeed = MouseLink.pref("airSpeed", 1.0) { didSet { UserDefaults.standard.set(airSpeed, forKey: "airSpeed") } }
    @Published var natural = (UserDefaults.standard.object(forKey: "naturalScroll") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(natural, forKey: "naturalScroll") }
    }
    @Published var air = (UserDefaults.standard.object(forKey: "airMouse") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(air, forKey: "airMouse"); if !air { stopAim() } }
    }

    private static func pref(_ k: String, _ d: Double) -> Double { (UserDefaults.standard.object(forKey: k) as? Double) ?? d }

    private var session: HIDSession?
    private var remX = 0.0, remY = 0.0
    private var scrollV = 0.0, scrollH = 0.0
    private let motion = CMMotionManager()
    private var aiming = false
    private var generation = 0

    var isReady: Bool { state == .ready }

    func start(host: String) {
        guard !host.isEmpty else { state = .failed("Set up the TV on Wi-Fi first."); return }
        if case .connecting = state { return }
        if state == .ready { return }
        state = .connecting("Connecting… if the TV asks to allow USB debugging, tick Always allow and press Allow.")
        generation += 1
        let gen = generation
        Task {
            do {
                let s = try await HIDSession.start(host: host) { [weak self] why in
                    Task { @MainActor in
                        self?.session = nil
                        self?.state = .failed(why)
                    }
                }
                guard gen == generation else { await s.stop(); return }
                session = s
                state = .ready
            } catch {
                if gen == generation { state = .failed(error.localizedDescription) }
            }
        }
    }

    func stop() {
        generation += 1
        stopAim()
        let s = session
        session = nil
        state = .off
        Task { await s?.stop() }
    }

    // Movement in screen points from the trackpad, with acceleration like a real pointer.
    func move(_ x: CGFloat, _ y: CGFloat, velocity: CGFloat) {
        guard let session, !air else { return }
        let gain = speed * (1 + accel * min(Double(velocity) / 900, 2.5))
        remX += Double(x) * gain
        remY += Double(y) * gain
        let ix = Int(remX.rounded(.towardZero)), iy = Int(remY.rounded(.towardZero))
        remX -= Double(ix)
        remY -= Double(iy)
        if ix != 0 || iy != 0 { session.input.move(ix, iy) }
    }

    /// Two-finger scroll: one wheel notch per 14 points.
    func scroll(_ x: CGFloat, _ y: CGFloat) {
        guard let session else { return }
        let sign = natural ? 1.0 : -1.0
        scrollV += Double(y) * sign / 14
        scrollH += Double(-x) * sign / 14
        let v = Int(scrollV.rounded(.towardZero)), h = Int(scrollH.rounded(.towardZero))
        scrollV -= Double(v)
        scrollH -= Double(h)
        if v != 0 || h != 0 { session.input.scroll(v, h) }
    }

    /// Wheel strip: whole notches.
    func wheel(_ notches: Int) {
        guard let session, notches != 0 else { return }
        session.input.scroll(notches, 0)
    }

    func click(_ mask: UInt8) {
        guard let session else { return }
        session.input.click(mask)
    }

    func button(_ mask: UInt8, down: Bool) {
        guard let session else { return }
        session.input.setButton(mask, down)
    }

    func type(_ text: String) {
        guard let session else { return }
        var reports: [[UInt8]] = []
        for ch in text {
            if let r = HIDKeys.report(for: ch) { reports.append(r); reports.append(HIDKeys.release) }
        }
        session.input.keys(reports)
    }

    func key(_ code: UInt8, times: Int = 1) {
        guard let session, times > 0 else { return }
        session.input.keys(Array((0..<times).flatMap { _ in HIDKeys.tap(code) }))
    }

    // MARK: Air mouse: point the phone, hold a finger on the pad to move.

    func startAim() {
        guard air, motion.isGyroAvailable, !aiming, session != nil else { return }
        aiming = true
        motion.gyroUpdateInterval = 1.0 / 120
        motion.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let r = data?.rotationRate else { return }
            MainActor.assumeIsolated { self.aim(r) }
        }
    }

    func stopAim() {
        guard aiming else { return }
        aiming = false
        motion.stopGyroUpdates()
    }

    private func aim(_ r: CMRotationRate) {
        guard let session else { return }
        let dz = 0.03
        let yaw = abs(r.z) < dz ? 0 : r.z, pitch = abs(r.x) < dz ? 0 : r.x
        let k = 900.0 * airSpeed / 120
        remX += -yaw * k
        remY += -pitch * k
        let ix = Int(remX.rounded(.towardZero)), iy = Int(remY.rounded(.towardZero))
        remX -= Double(ix)
        remY -= Double(iy)
        if ix != 0 || iy != 0 { session.input.move(ix, iy) }
    }
}
