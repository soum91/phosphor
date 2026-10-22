import SwiftUI
import UIKit

/// The mouse page: a trackpad that drives the TV's real pointer, laptop-style click buttons, a notched scroll
/// wheel, an air-mouse mode (point the phone) and a real keyboard.
struct MouseView: View {
    @EnvironmentObject var store: Store
    @StateObject private var link = MouseLink()
    @Environment(\.scenePhase) private var phase
    @State private var showSettings = false
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var keyboardUp: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background(Theme.accent, strength: link.isReady ? 0.18 : 0.08)
            VStack(spacing: 14) {
                statusBar
                HStack(spacing: 12) {
                    Trackpad(link: link)
                        .overlay {
                            if !link.isReady { notReady }
                        }
                    ScrollWheel(link: link)
                        .frame(width: 54)
                }
                .frame(maxHeight: .infinity)
                ClickButtons(link: link)
                    .frame(height: 86)
                bottomRow
                if typing { keyboardBar }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            if let t = store.toast { Toast(text: t).padding(.bottom, 24) }
        }
        .navigationTitle("Mouse")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showSettings) { MouseSettings(link: link).presentationDetents([.medium, .large]) }
        .onAppear { link.start(host: store.tv.host) }
        .onDisappear { link.stop() }
        .onChange(of: phase) { _, p in
            if p == .active { link.start(host: store.tv.host) } else if p == .background { link.stop() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(link.isReady ? Theme.accent : (link.state == .off ? Theme.off : Theme.danger))
                .frame(width: 8, height: 8)
                .shadow(color: link.isReady ? Theme.accent : .clear, radius: 4)
            Text(link.state.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if link.air {
                Label("Air", systemImage: "scope").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
    }

    private var notReady: some View {
        VStack(spacing: 12) {
            if case .connecting = link.state {
                ProgressView()
            } else {
                Image(systemName: "cursorarrow.rays").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("The mouse uses ADB. On the TV: Developer options › USB debugging on. The first time, allow debugging (tick Always allow).")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Connect") { link.start(host: store.tv.host) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private var bottomRow: some View {
        HStack(spacing: 0) {
            KeyButton(symbol: "arrow.uturn.backward", label: "Back", size: 50) { store.press("Return") }
                .frame(maxWidth: .infinity)
            KeyButton(symbol: "house.fill", label: "Home", size: 50) { store.press("Home") }
                .frame(maxWidth: .infinity)
            KeyButton(symbol: "keyboard", label: "Keyboard", size: 50, filled: typing) {
                typing.toggle()
                keyboardUp = typing
            }
            .frame(maxWidth: .infinity)
            KeyButton(symbol: link.air ? "scope" : "hand.point.up.left", label: link.air ? "Air mouse" : "Trackpad", size: 50, filled: link.air) {
                link.air.toggle()
            }
            .frame(maxWidth: .infinity)
            KeyButton(symbol: "playpause.fill", label: "Play/Pause", size: 50) { store.press(store.state.input == "Apps" ? "Pause" : "Play") }
                .frame(maxWidth: .infinity)
        }
    }

    /// Types straight into whatever has focus on the TV, as a real keyboard.
    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField("Type on the TV", text: $typed)
                .focused($keyboardUp)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.return)
                .onChange(of: typed) { old, new in sendDiff(old, new) }
                .onSubmit {
                    link.key(HIDKeys.enter)
                    typed = ""
                    keyboardUp = true
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            smallKey("delete.left") { link.key(HIDKeys.backspace); if !typed.isEmpty { typed.removeLast() } }
            smallKey("arrow.left") { link.key(HIDKeys.left) }
            smallKey("arrow.right") { link.key(HIDKeys.right) }
        }
    }

    private func smallKey(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 42)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }

    /// Sends what changed in the text field: backspaces for what was removed, then the new characters.
    private func sendDiff(_ old: String, _ new: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        let removed = old.count - common
        if removed > 0 { link.key(HIDKeys.backspace, times: removed) }
        let added = String(new.dropFirst(common))
        if !added.isEmpty { link.type(added) }
    }
}

// MARK: - Trackpad

struct Trackpad: View {
    @ObservedObject var link: MouseLink

    var body: some View {
        TrackpadSurfaceView(link: link)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.09), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.deep.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            )
            .shadow(color: Theme.accent.opacity(link.isReady ? 0.25 : 0), radius: 14)
            .overlay(alignment: .bottom) {
                if link.isReady {
                    Text(link.air ? "Hold a finger here and point the phone · tap to click" : "Tap to click · two-finger tap: right click · two fingers: scroll · tap, then hold and drag")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.28))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct TrackpadSurfaceView: UIViewRepresentable {
    let link: MouseLink

    func makeUIView(context: Context) -> TrackpadSurface {
        let v = TrackpadSurface()
        v.link = link
        return v
    }

    func updateUIView(_ v: TrackpadSurface, context: Context) { v.link = link }
}

/// Raw multitouch, so movement is 1:1 with the finger at the screen's full touch rate.
final class TrackpadSurface: UIView {
    weak var link: MouseLink?

    private var active: Set<UITouch> = []
    private var startTime: TimeInterval = 0
    private var travelled: CGFloat = 0
    private var maxFingers = 0
    private var lastCentroid: CGPoint?
    private var lastTime: TimeInterval = 0
    private var lastTapEnd: TimeInterval = 0
    private var dragging = false
    private let tapHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func centroid(_ touches: Set<UITouch>) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let pts = touches.map { $0.location(in: self) }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = active.isEmpty
        active.formUnion(touches)
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if wasEmpty {
            startTime = now
            travelled = 0
            maxFingers = active.count
            // Tap, then touch again quickly and hold: drag with the button down (like a laptop trackpad).
            if active.count == 1, now - lastTapEnd < 0.3 {
                dragging = true
                link?.button(1, down: true)
                softHaptic.impactOccurred()
            }
            link?.startAim()
        } else {
            maxFingers = max(maxFingers, active.count)
        }
        lastCentroid = centroid(active)
        lastTime = now
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let last = lastCentroid else { return }
        let c = centroid(active)
        let dx = c.x - last.x, dy = c.y - last.y
        lastCentroid = c
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastTime, 1.0 / 240)
        lastTime = now
        let dist = hypot(dx, dy)
        travelled += dist
        if active.count >= 2 {
            link?.scroll(dx, dy)
        } else {
            link?.move(dx, dy, velocity: dist / CGFloat(dt))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?, cancelled: Bool) {
        active.subtract(touches)
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if !active.isEmpty {
            lastCentroid = centroid(active)
            return
        }
        lastCentroid = nil
        link?.stopAim()
        if dragging {
            dragging = false
            link?.button(1, down: false)
            lastTapEnd = 0
            return
        }
        guard !cancelled else { return }
        let quick = now - startTime < 0.28
        let still = travelled < (link?.air == true ? 30 : 9)
        if quick && still {
            if maxFingers >= 2 {
                link?.click(2)
                lastTapEnd = 0
            } else {
                link?.click(1)
                lastTapEnd = now
            }
            tapHaptic.impactOccurred(intensity: 0.8)
        } else {
            lastTapEnd = 0
        }
    }
}

// MARK: - Click buttons

/// Left and right buttons that press on touch-down and release on lift, so you can hold one and drag on the pad.
struct ClickButtons: View {
    @ObservedObject var link: MouseLink

    var body: some View {
        HStack(spacing: 10) {
            PhysicalButton(title: "Left", corner: [.bottomLeft]) { link.button(1, down: $0) }
            PhysicalButton(title: "Right", corner: [.bottomRight]) { link.button(2, down: $0) }
        }
        .opacity(link.isReady ? 1 : 0.4)
        .disabled(!link.isReady)
    }
}

struct PhysicalButton: View {
    let title: String
    let corner: UIRectCorner
    let changed: (Bool) -> Void
    @State private var down = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: down ? [Color(white: 0.05), Color(white: 0.09)] : [Color(white: 0.13), Color(white: 0.06)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(down ? Theme.accent : Theme.stroke, lineWidth: down ? 1.5 : 1))
            .overlay(Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(down ? 0.9 : 0.5)))
            .shadow(color: down ? Theme.accent.opacity(0.4) : .black.opacity(0.4), radius: down ? 10 : 6, y: down ? 0 : 4)
            .scaleEffect(down ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: down)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down {
                            down = true
                            changed(true)
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        down = false
                        changed(false)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                    }
            )
    }
}

// MARK: - Scroll wheel

/// A notched wheel: drag to roll it, a click of haptics per notch, like a real mouse wheel.
struct ScrollWheel: View {
    @ObservedObject var link: MouseLink
    @State private var last: CGFloat = 0
    @State private var acc: CGFloat = 0
    @State private var phase: CGFloat = 0
    private let notch: CGFloat = 16
    private let tick = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.04), Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                // Ridges that roll with your finger.
                Canvas { ctx, size in
                    let spacing: CGFloat = 9
                    var y = phase.truncatingRemainder(dividingBy: spacing) - spacing
                    while y < size.height + spacing {
                        let mid = size.height / 2
                        let fade = max(0, 1 - abs(y - mid) / mid)
                        let w = size.width * (0.35 + 0.35 * fade)
                        let rect = CGRect(x: (size.width - w) / 2, y: y, width: w, height: 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.08 + 0.3 * fade)))
                        y += spacing
                    }
                }
                .padding(.vertical, 10)
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d = v.translation.height - last
                        last = v.translation.height
                        phase += d
                        acc += d
                        let n = Int(acc / notch)
                        if n != 0 {
                            acc -= CGFloat(n) * notch
                            // Rolling the wheel toward you (finger down) scrolls down, like a real mouse.
                            link.wheel(-n)
                            tick.selectionChanged()
                        }
                    }
                    .onEnded { _ in last = 0; acc = 0 }
            )
            .frame(height: geo.size.height)
        }
        .opacity(link.isReady ? 1 : 0.4)
        .disabled(!link.isReady)
    }
}

// MARK: - Settings

struct MouseSettings: View {
    @ObservedObject var link: MouseLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                Form {
                    Section("Trackpad") {
                        VStack(alignment: .leading) {
                            Text("Pointer speed")
                            Slider(value: $link.speed, in: 0.5...4).tint(Theme.accent)
                        }
                        VStack(alignment: .leading) {
                            Text("Acceleration")
                            Slider(value: $link.accel, in: 0...2.5).tint(Theme.accent)
                        }
                        Toggle("Natural scrolling", isOn: $link.natural).tint(Theme.accent)
                    }
                    Section {
                        Toggle("Air mouse", isOn: $link.air).tint(Theme.accent)
                        VStack(alignment: .leading) {
                            Text("Air speed")
                            Slider(value: $link.airSpeed, in: 0.3...3).tint(Theme.accent)
                        }
                    } footer: {
                        Text("Point the top of the phone at the TV and keep a finger on the pad; the pointer follows the phone. Lift to stop, tap to click.")
                    }
                    Section {
                        Text("Android sees a real USB mouse and keyboard (made with its built-in hid tool over ADB), so the pointer, clicks, wheel and dragging are the TV's own. Right click is Back on Android TV.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Mouse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
