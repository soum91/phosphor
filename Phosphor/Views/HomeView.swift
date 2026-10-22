import SwiftUI

/// Two pages: the TV, and the remote with every button.
struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("TV", systemImage: "tv.fill") }
                .tag(0)
            NavigationStack { RemoteView() }
                .tabItem { Label("Remote", systemImage: "av.remote.fill") }
                .tag(1)
        }
        .sheet(item: Binding(get: { store.learning }, set: { if $0 == nil { store.endLearn() } })) { _ in
            LearnSheet().environmentObject(store).presentationDetents([.medium])
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var cast = Store.shared.cast
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var showKeyboard = false
    @State private var editing: TVPreset?

    private var isOn: Bool { store.state.power == true }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background(isOn ? Theme.accent : Theme.off, strength: isOn ? 0.22 : 0.10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if !store.isSetUp {
                            setupCard
                        } else {
                            if store.authFailed { authCard }
                            powerAndVolume
                            quickRow
                            inputsRow
                            presetsRow
                            if cast.status.app != nil && !cast.status.isIdleScreen { NowPlayingCard() }
                            appsGrid
                            moreCard
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
                .refreshable { await store.refresh(full: true) }

                if let t = store.toast { Toast(text: t).padding(.bottom, 24) }
            }
            .animation(.easeInOut(duration: 0.2), value: store.toast)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSetup) { SetupView().environmentObject(store) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
            .sheet(isPresented: $showKeyboard) { KeyboardSheet().environmentObject(store).presentationDetents([.height(260)]) }
            .sheet(item: $editing) { p in PresetEditor(preset: p).environmentObject(store) }
        }
    }

    // MARK: Header

    private var statusText: String {
        let s = store.state
        var parts: [String] = []
        switch s.power {
        case true?: parts.append(s.screenOff == true ? "Screen off" : "On")
        case false?: parts.append("Standby")
        default: parts.append(store.tv.hasWiFi ? "Not answering" : "IR only")
        }
        if s.power == true, let i = s.input { parts.append(i) }
        if let v = store.lastPath?.rawValue ?? s.via { parts.append("via \(v)") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.tv.name.isEmpty ? "Phosphor" : store.tv.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if store.isSetUp {
                    HStack(spacing: 6) {
                        Circle().fill(isOn ? Theme.accent : Theme.off).frame(width: 8, height: 8)
                        Text(statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let m = store.tv.model { Text(m).font(.caption).foregroundStyle(.white.opacity(0.35)) }
                }
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Theme.card, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "tv.and.mediabox.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Let's find your TV").font(.title2.bold())
            Text("Phosphor talks to the Bravia straight over your Wi-Fi (Sony's IP control) and through your Tuya IR blaster when the TV is asleep or its network side isn't answering. No Sony or Google account.")
                .foregroundStyle(.secondary)
            Button { showSetup = true } label: {
                Text("Set up").fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
        }
        .card()
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The TV turned down the key", systemImage: "key.slash").font(.headline).foregroundStyle(Theme.danger)
            Text("Check Settings › Network & Internet › Home network › IP control on the TV, then fix it in Phosphor's settings. IR still works meanwhile.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open settings") { showSettings = true }.font(.callout.weight(.semibold))
        }
        .card()
    }

    // MARK: Power and volume

    private var maxVolume: Double { Double(max(store.state.maxVolume ?? 100, 1)) }
    private var volumeValue: Double { Double(store.state.volume ?? 0) }

    private var powerAndVolume: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                Button { store.togglePower() } label: {
                    Image(systemName: "power")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 84, height: 84)
                        .background(isOn ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(isOn ? .black : .white)
                        .overlay(Circle().stroke(Theme.stroke))
                        .shadow(color: isOn ? Theme.accent.opacity(0.5) : .clear, radius: 18)
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    Button { store.perform(.power(true)) } label: { Label("Power on", systemImage: "power.circle.fill") }
                    Button { store.perform(.power(false)) } label: { Label("Power off", systemImage: "power.circle") }
                    Button { store.testIR("WakeUp") } label: { Label("Power on over IR", systemImage: "dot.radiowaves.right") }
                    Button { store.testIR("PowerOff") } label: { Label("Power off over IR", systemImage: "dot.radiowaves.right") }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.state.volume.map { "\($0)" } ?? "–")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(store.state.muted == true ? Theme.off : .white)
                    Text(store.state.muted == true ? "Muted" : "Volume").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.perform(.mute(nil)) } label: {
                    Image(systemName: store.state.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .background(store.state.muted == true ? Theme.danger : Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(store.state.muted == true ? .black : .white)
                }
                .buttonStyle(PressStyle())
            }

            HStack(spacing: 12) {
                stepButton("minus") { store.perform(.volumeDown(1)) }
                if store.tv.hasWiFi && store.tv.route != .ir {
                    Slider(value: Binding(get: { min(store.volumeDraft ?? volumeValue, maxVolume) }, set: { store.setVolumeLive($0) }),
                           in: 0...maxVolume, step: 1)
                        .tint(Theme.accent)
                } else {
                    Text("IR: hold to repeat").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                stepButton("plus") { store.perform(.volumeUp(1)) }
            }
        }
        .card()
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        RepeatButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.08), in: Circle())
                .foregroundStyle(.white)
        }
    }

    // MARK: Quick buttons

    private var quickRow: some View {
        HStack(spacing: 0) {
            KeyButton(symbol: store.state.screenOff == true ? "tv" : "tv.slash", label: store.state.screenOff == true ? "Screen on" : "Screen off",
                      size: 52, filled: store.state.screenOff == true) {
                store.perform(.screen(store.state.screenOff == true))
            }
            .frame(maxWidth: .infinity)
            KeyButton(symbol: "house.fill", label: "Home", size: 52) { store.perform(.key("Home")) }
                .frame(maxWidth: .infinity)
            KeyButton(symbol: "arrow.uturn.backward", label: "Back", size: 52) { store.perform(.key("Return")) }
                .frame(maxWidth: .infinity)
            KeyButton(symbol: "keyboard", label: "Type", size: 52) { showKeyboard = true }
                .frame(maxWidth: .infinity)
                .disabled(!store.tv.hasWiFi)
            KeyButton(symbol: "playpause.fill", label: "Play/Pause", size: 52) {
                if cast.status.media != nil { cast.playPause() } else { store.perform(.key(store.state.input == "Apps" ? "Pause" : "Play")) }
            }
            .frame(maxWidth: .infinity)
            .contextMenu {
                Button { store.perform(.key("Play")) } label: { Label("Play", systemImage: "play.fill") }
                Button { store.perform(.key("Pause")) } label: { Label("Pause", systemImage: "pause.fill") }
            }
        }
        .card()
    }

    // MARK: Inputs

    private struct InputChoice: Identifiable {
        let id: String
        let label: String
        let connected: Bool
    }

    private var inputChoices: [InputChoice] {
        if !store.inputs.isEmpty {
            return store.inputs.map { InputChoice(id: $0.uri, label: $0.name, connected: $0.connected) }
        }
        return Keys.builtin.filter { $0.group == .inputs && $0.id != "Input" }.map { InputChoice(id: $0.id, label: $0.label, connected: true) }
    }

    private func isCurrent(_ c: InputChoice) -> Bool {
        if let uri = store.state.inputURI { return uri == c.id }
        return store.state.input?.lowercased() == c.label.lowercased()
    }

    private var inputsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Input")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(inputChoices) { c in
                        Button { store.perform(.input(c.id)) } label: {
                            Chip(title: c.label, symbol: c.connected ? "cable.connector" : "cable.connector.slash", selected: isCurrent(c))
                                .opacity(c.connected || isCurrent(c) ? 1 : 0.55)
                        }
                    }
                    Button { store.perform(.key("Input")) } label: { Chip(title: "Cycle", symbol: "rectangle.portrait.and.arrow.forward") }
                }
            }
        }
    }

    // MARK: Presets

    private var presetsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Presets")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.presets) { p in
                        Button { store.run(p) } label: { Chip(title: p.name, symbol: p.icon) }
                            .contextMenu {
                                Button { editing = p } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { store.deletePreset(p.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    Button { editing = TVPreset(name: "New preset", icon: "sparkles") } label: { Chip(title: "", symbol: "plus") }
                }
            }
            Text("Tap to run, long-press to edit.").font(.caption2).foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: Apps

    private var appsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Apps")
            if store.apps.isEmpty {
                Text(store.tv.hasWiFi ? "The app list loads once the TV is on." : "Apps need the TV on Wi-Fi. Netflix and YouTube still work over IR from the remote page.")
                    .font(.callout).foregroundStyle(.secondary)
                    .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 12)], spacing: 14) {
                    ForEach(store.apps) { a in
                        Button { store.open(a) } label: { AppTile(app: a) }
                            .buttonStyle(PressStyle())
                    }
                }
            }
        }
    }

    private var moreCard: some View {
        VStack(spacing: 0) {
            ForEach(Bravia.settingGroups, id: \.title) { g in
                NavigationLink { SettingsGroupView(group: g) } label: {
                    row(g.title, g.title == "Picture" ? "sparkles.tv" : (g.title == "Sound" ? "waveform" : "hifispeaker.2"),
                        g.title == "Picture" ? "Picture mode, brightness, color, motion…" : (g.title == "Sound" ? "Sound mode, output, surround…" : "Speaker and sound bar options"))
                }
                .disabled(!store.tv.hasWiFi)
                Divider().overlay(Theme.stroke)
            }
            NavigationLink { RemoteView() } label: { row("Remote", "av.remote.fill", "Every button, learn mode") }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }

    private func row(_ title: String, _ symbol: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct AppTile: View {
    let app: BraviaApp

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: app.iconURL) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: Apps.symbol(app.title)).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.stroke))
            Text(app.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Fires once on tap and keeps firing while held, like a real remote.
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(response: 0.2), value: pressed)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30, perform: {}, onPressingChanged: { down in
                pressed = down
                if down {
                    action()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                        Task { @MainActor in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { _ in
                                Task { @MainActor in action() }
                            }
                        }
                    }
                } else {
                    timer?.invalidate()
                    timer = nil
                }
            })
    }
}

// MARK: - Typing

struct KeyboardSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.background()
            VStack(alignment: .leading, spacing: 14) {
                Text("Type on the TV").font(.title3.bold())
                TextField("Search, email, password…", text: $text)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
                    .onChange(of: text) { _, t in live(t) }
                    .onSubmit {
                        store.perform(.text(text))
                        store.perform(.key("Confirm"))
                        dismiss()
                    }
                Text("Open a search or text box on the TV first. What you type shows up there as you go; Return presses OK.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { focused = true }
    }

    private func live(_ t: String) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do { try await TV.perform(.text(t), cfg: store.tv) } catch { store.show(error.localizedDescription) }
        }
    }
}

// MARK: - Now playing (the TV's built-in Chromecast)

struct NowPlayingCard: View {
    @ObservedObject private var cast = Store.shared.cast
    @State private var scrub: Double?

    var body: some View {
        let s = cast.status
        let m = s.media
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Casting · \(s.app ?? "")")
                Spacer()
                Button { cast.stopApp() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
            }
            HStack(spacing: 14) {
                AsyncImage(url: m?.artURL) { img in img.resizable().scaledToFill() } placeholder: {
                    ZStack { Theme.card; Image(systemName: "play.tv").foregroundStyle(.white.opacity(0.4)) }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m?.title ?? s.app ?? "Casting").font(.headline).lineLimit(1)
                    if let sub = m?.subtitle { Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            if let m, let d = m.duration, d > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { scrub ?? m.livePosition }, set: { scrub = $0 }), in: 0...d, onEditingChanged: { editing in
                            if !editing, let v = scrub { cast.seek(v); scrub = nil }
                        })
                        .tint(.white)
                        .disabled(!m.canSeek)
                        HStack {
                            Text(Self.time(scrub ?? m.livePosition))
                            Spacer()
                            Text(Self.time(d))
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button { cast.previous() } label: { Image(systemName: "backward.fill").font(.title2) }.disabled(m == nil)
                Spacer()
                Button { cast.playPause() } label: {
                    Image(systemName: m?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(Color.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .disabled(m == nil)
                Spacer()
                Button { cast.next() } label: { Image(systemName: "forward.fill").font(.title2) }.disabled(m == nil)
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .card()
    }

    static func time(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Picture / sound settings from the TV

struct SettingsGroupView: View {
    @EnvironmentObject var store: Store
    let group: Bravia.SettingsGroup
    @State private var items: [BraviaSetting] = []
    @State private var loading = true
    @State private var error: String?
    @State private var drafts: [String: Double] = [:]

    var body: some View {
        ZStack {
            Theme.background()
            List {
                if loading && items.isEmpty {
                    HStack { ProgressView(); Text("Asking the TV…").foregroundStyle(.secondary) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
                ForEach(items) { s in
                    row(s).disabled(!s.available)
                }
                if !loading && items.isEmpty && error == nil {
                    Text("The TV didn't report any \(group.title.lowercased()) settings. Turn it on and pull to refresh.").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ s: BraviaSetting) -> some View {
        if s.isToggle {
            Toggle(s.title, isOn: Binding(get: { s.value.lowercased() == "on" }, set: { set(s, $0 ? "on" : "off") }))
                .tint(Theme.accent)
        } else if !s.choices.isEmpty {
            Picker(s.title, selection: Binding(get: { s.value }, set: { set(s, $0) })) {
                ForEach(s.choices, id: \.value) { c in Text(c.title).tag(c.value) }
                if !s.choices.contains(where: { $0.value == s.value }) { Text(Keys.prettify(s.value)).tag(s.value) }
            }
        } else if s.isRange, let mn = s.min, let mx = s.max {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.title)
                    Spacer()
                    Text(String(Int((drafts[s.id] ?? Double(s.value) ?? mn).rounded()))).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { drafts[s.id] ?? Double(s.value) ?? mn }, set: { drafts[s.id] = $0 }),
                       in: mn...mx, step: max(s.step ?? 1, 1), onEditingChanged: { editing in
                    if !editing, let v = drafts[s.id] { set(s, String(Int(v.rounded()))) }
                })
                .tint(Theme.accent)
            }
        } else {
            LabeledContent(s.title, value: Keys.prettify(s.value))
        }
    }

    private func set(_ s: BraviaSetting, _ value: String) {
        guard let b = Bravia(store.tv) else { return }
        if let i = items.firstIndex(where: { $0.id == s.id }) { items[i].value = value }
        Task {
            do {
                try await b.apply(s, value)
                try? await Task.sleep(nanoseconds: 300_000_000)
                await load()
                drafts[s.id] = nil
            } catch {
                store.show(error.localizedDescription)
                await load()
            }
        }
    }

    private func load() async {
        guard let b = Bravia(store.tv) else { loading = false; return }
        loading = true
        defer { loading = false }
        do {
            items = try await b.settings(group)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
