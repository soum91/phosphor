import SwiftUI
import UniformTypeIdentifiers

/// Every button on the Bravia remote, plus anything else the TV reports. Taps go over Wi-Fi (IRCC) and fall back
/// to the IR blaster. Learn mode records a button from the real remote into the blaster.
struct RemoteView: View {
    @EnvironmentObject var store: Store
    @State private var learnMode = false
    @State private var importing = false
    @State private var irOnly = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background(learnMode ? Color(red: 1, green: 0.4, blue: 0.4) : Theme.accent, strength: 0.16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RemoteFace(tap: tap)
                    SectionTitle(text: "Every button")
                    if learnMode {
                        Text("Learn mode: tap a button here, then press the same button on your Sony remote, aimed at the blaster.")
                            .font(.callout)
                            .card()
                    } else if !store.blaster.isReady {
                        Text("No IR blaster set up, so these only go over Wi-Fi. Set the blaster up in Settings so the TV can be woken and driven when its network side is asleep.")
                            .font(.callout).foregroundStyle(.secondary)
                            .card()
                    }
                    ForEach(KeyGroup.allCases) { g in
                        let keys = Keys.all(remote: store.remote).filter { $0.group == g }
                        if !keys.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(text: g.rawValue)
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(keys) { k in
                                        KeyButton(symbol: k.symbol, label: k.label, size: 56,
                                                  tint: learnMode ? Color(red: 1, green: 0.55, blue: 0.5) : RemoteFace.tint(k.id),
                                                  badge: store.codes[k.id] != nil) {
                                            tap(k)
                                        }
                                        .contextMenu { menu(k) }
                                    }
                                }
                            }
                        }
                    }
                    Text("A dot means the button was learned from your remote. The rest use Sony's codes: the TV's own list over Wi-Fi, turned into SIRC for IR. If one does nothing over IR, long-press it and learn it.")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            if let t = store.toast { Toast(text: t).padding(.bottom, 24) }
        }
        .navigationTitle("Remote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $learnMode) { Label("Learn mode", systemImage: "record.circle") }
                        .disabled(!store.blaster.isReady)
                    Toggle(isOn: $irOnly) { Label("Always send IR", systemImage: "dot.radiowaves.right") }
                        .disabled(!store.blaster.isReady)
                    Button { importing = true } label: { Label("Import from Redshift", systemImage: "square.and.arrow.down") }
                    Button { Task { await store.loadLists() } } label: { Label("Reload the TV's buttons", systemImage: "arrow.clockwise") }
                        .disabled(!store.tv.hasWiFi)
                } label: {
                    Image(systemName: learnMode ? "record.circle.fill" : "ellipsis.circle")
                        .foregroundStyle(learnMode ? Color(red: 1, green: 0.45, blue: 0.45) : Theme.accent)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            if case .success(let url) = r { store.importRedshift(from: url) }
        }
    }

    @ViewBuilder
    private func menu(_ k: KeyDef) -> some View {
        if store.blaster.isReady {
            Button { store.startLearn(k.id) } label: { Label("Learn from remote", systemImage: "record.circle") }
            Button { store.testIR(k.id) } label: { Label("Send over IR", systemImage: "dot.radiowaves.right") }
        }
        if store.codes[k.id] != nil {
            Button(role: .destructive) { store.codes[k.id] = nil } label: {
                Label("Forget learned code", systemImage: "trash")
            }
        }
    }

    private func tap(_ k: KeyDef) {
        if learnMode {
            store.startLearn(k.id)
        } else if irOnly {
            store.testIR(k.id)
        } else {
            switch k.id {
            case "WakeUp": store.perform(.power(true))
            case "PowerOff": store.perform(.power(false))
            case "TvPower": store.togglePower()
            default: store.perform(.key(k.id))
            }
        }
    }
}

struct LearnSheet: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Theme.background(Color(red: 1, green: 0.4, blue: 0.4), strength: 0.2)
            VStack(spacing: 18) {
                if let s = store.learning {
                    Text("Learning \(s.label)").font(.title2.bold())
                    switch s.phase {
                    case .starting:
                        ProgressView("Putting the blaster in learn mode…")
                    case .waiting:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 44))
                            .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                            .symbolEffect(.variableColor.iterative)
                        Text("Point the Sony remote at the blaster from 5 to 10 cm and press **\(s.label)** once.")
                            .multilineTextAlignment(.center)
                    case .captured(let n):
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        Text("Got it (\(n) pulses).")
                        HStack {
                            Button("Test") { store.testIR(s.keyID) }.buttonStyle(.bordered)
                            Button("Learn again") { store.startLearn(s.keyID) }.buttonStyle(.bordered)
                            Button("Done") { store.endLearn() }.buttonStyle(.borderedProminent)
                        }
                    case .failed(let why):
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.danger)
                        Text(why).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        HStack {
                            Button("Try again") { store.startLearn(s.keyID) }.buttonStyle(.borderedProminent)
                            Button("Cancel") { store.endLearn() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

/// The remote laid out like the Bravia one: power and input up top, the d-pad ring, back/home/options,
/// volume and channel rockers, transport, then the app and color buttons.
struct RemoteFace: View {
    @EnvironmentObject var store: Store
    let tap: (KeyDef) -> Void

    static func tint(_ id: String) -> Color {
        switch id {
        case "Red": return Color(red: 1, green: 0.35, blue: 0.35)
        case "Green": return Color(red: 0.35, green: 0.85, blue: 0.45)
        case "Yellow": return Color(red: 1, green: 0.85, blue: 0.3)
        case "Blue": return Color(red: 0.35, green: 0.6, blue: 1)
        case "Netflix": return Color(red: 0.9, green: 0.1, blue: 0.15)
        case "YouTube": return Color(red: 1, green: 0.2, blue: 0.2)
        default: return .white
        }
    }

    private func def(_ id: String) -> KeyDef { Keys.def(id) ?? KeyDef(id, id, nil, .other, nil) }

    private func key(_ id: String, size: CGFloat = 54, filled: Bool = false) -> some View {
        let d = def(id)
        return KeyButton(symbol: d.symbol, label: d.label, size: size, tint: filled ? Theme.accent : Self.tint(id), filled: filled,
                         badge: store.codes[id] != nil) { tap(d) }
    }

    private func rocker(_ title: String, up: String, down: String) -> some View {
        VStack(spacing: 0) {
            RepeatButton(action: { tap(def(up)) }) {
                Image(systemName: "plus").font(.system(size: 20, weight: .bold)).frame(width: 64, height: 62).contentShape(Rectangle())
            }
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 4)
            RepeatButton(action: { tap(def(down)) }) {
                Image(systemName: "minus").font(.system(size: 20, weight: .bold)).frame(width: 64, height: 62).contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
    }

    private func arrow(_ id: String, _ symbol: String) -> some View {
        RepeatButton(action: { tap(def(id)) }) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 62, height: 62)
                .contentShape(Rectangle())
                .foregroundStyle(.white)
        }
    }

    /// The ring: arrows around a big OK. Hold an arrow to scroll.
    private var dpad: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.07)).overlay(Circle().stroke(Theme.stroke))
            VStack(spacing: 0) {
                arrow("Up", "chevron.up")
                HStack(spacing: 0) {
                    arrow("Left", "chevron.left")
                    Button { tap(def("Confirm")) } label: {
                        Text("OK").font(.system(size: 17, weight: .bold, design: .rounded))
                            .frame(width: 74, height: 74)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(PressStyle())
                    arrow("Right", "chevron.right")
                }
                arrow("Down", "chevron.down")
            }
        }
        .frame(width: 210, height: 210)
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                key("TvPower", size: 60, filled: store.state.power == true)
                Spacer()
                if let v = store.state.volume, store.state.power == true {
                    Text("\(v)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(store.state.muted == true ? Theme.off : .white)
                }
                Spacer()
                key("Input", size: 60)
            }
            HStack {
                key("ActionMenu", size: 48)
                Spacer()
                key("Assists", size: 48)
                Spacer()
                key("Display", size: 48)
            }
            dpad
            HStack {
                key("Return")
                Spacer()
                key("Home")
                Spacer()
                key("Options")
            }
            HStack(alignment: .center) {
                rocker("VOL", up: "VolumeUp", down: "VolumeDown")
                Spacer()
                VStack(spacing: 18) {
                    key("Mute", size: 58)
                    key("GGuide", size: 58)
                }
                Spacer()
                rocker("CH", up: "ChannelUp", down: "ChannelDown")
            }
            Divider().overlay(Theme.stroke)
            HStack {
                key("Rewind")
                Spacer()
                key("Play")
                Spacer()
                key("Pause")
                Spacer()
                key("Forward")
            }
            HStack {
                key("Prev")
                Spacer()
                key("Stop")
                Spacer()
                key("SubTitle")
                Spacer()
                key("Next")
            }
            Divider().overlay(Theme.stroke)
            HStack {
                key("Netflix")
                Spacer()
                key("YouTube")
                Spacer()
                key("GooglePlay")
                Spacer()
                key("PicOff")
            }
            HStack {
                key("Red", size: 44)
                Spacer()
                key("Green", size: 44)
                Spacer()
                key("Yellow", size: 44)
                Spacer()
                key("Blue", size: 44)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}
