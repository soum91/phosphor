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
            NavigationStack { MouseView() }
                .tabItem { Label("Mouse", systemImage: "cursorarrow.rays") }
                .tag(2)
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
    @State private var editMode = false
    @State private var addingApp = false
    @State private var addingQuick = false

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
                            if editMode { editBanner }
                            ForEach(store.home.sections) { s in section(s) }
                            if editMode { editFooter }
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
            .sheet(isPresented: $addingApp) { AddAppSheet().environmentObject(store) }
            .sheet(isPresented: $addingQuick) {
                ButtonPicker(includeSpecials: true, exclude: store.home.quick) { id in
                    if store.home.quick.count < HomeLayout.maxQuick { store.home.quick.append(id) }
                }
                .environmentObject(store)
            }
        }
    }

    // MARK: Sections and edit mode

    @ViewBuilder
    private func section(_ s: HomeLayout.Section) -> some View {
        let hidden = store.home.hidden.contains(s)
        if editMode {
            VStack(alignment: .leading, spacing: 10) {
                sectionBar(s, hidden: hidden)
                if !hidden { content(s) }
            }
        } else if !hidden {
            content(s)
        }
    }

    @ViewBuilder
    private func content(_ s: HomeLayout.Section) -> some View {
        switch s {
        case .power: powerAndVolume
        case .quick: quickRow
        case .inputs: inputsRow
        case .presets: presetsRow
        case .nowPlaying:
            if cast.status.app != nil && !cast.status.isIdleScreen {
                NowPlayingCard()
            } else if editMode {
                Text("Shows up while something is casting to the TV.").font(.caption).foregroundStyle(.secondary)
            }
        case .apps: appsGrid
        case .sideloaded: sideApps
        case .settings: moreCard
        }
    }

    private func sectionBar(_ s: HomeLayout.Section, hidden: Bool) -> some View {
        let list = store.home.sections
        let i = list.firstIndex(of: s) ?? 0
        return HStack(spacing: 14) {
            Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(hidden ? .white.opacity(0.4) : .white)
            Spacer()
            Button { withAnimation { store.home.moveSection(s, by: -1) } } label: { Image(systemName: "chevron.up") }
                .disabled(i == 0)
            Button { withAnimation { store.home.moveSection(s, by: 1) } } label: { Image(systemName: "chevron.down") }
                .disabled(i == list.count - 1)
            Button {
                withAnimation {
                    if hidden { store.home.hidden.removeAll { $0 == s } } else { store.home.hidden.append(s) }
                }
            } label: { Image(systemName: hidden ? "eye.slash" : "eye") }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Theme.accent.opacity(0.35)))
    }

    private var editBanner: some View {
        Text("Drag buttons and apps onto each other to move them, tap − to remove, + to add. Arrows move whole sections, the eye hides one.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var editFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.home.hiddenApps.isEmpty {
                Button("Show \(store.home.hiddenApps.count) hidden app\(store.home.hiddenApps.count == 1 ? "" : "s")") {
                    store.home.hiddenApps = []
                }
            }
            Button("Reset the home page", role: .destructive) { withAnimation { store.home = HomeLayout() } }
        }
        .font(.callout.weight(.semibold))
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
                Text(store.tv.name.isEmpty ? "Obsidian" : store.tv.name)
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
            if store.isSetUp {
                Button { withAnimation(.spring(response: 0.3)) { editMode.toggle() } } label: {
                    Image(systemName: editMode ? "checkmark" : "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(editMode ? Theme.accent : Theme.card, in: Circle())
                        .foregroundStyle(editMode ? .black : .white)
                }
            }
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
            Text("Obsidian talks to the Bravia straight over your Wi-Fi (Sony's IP control) and through your Tuya IR blaster when the TV is asleep or its network side isn't answering. No Sony or Google account.")
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
            Text("Check Settings › Network & Internet › Home network › IP control on the TV, then fix it in Obsidian's settings. IR still works meanwhile.")
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 14) {
            ForEach(store.home.quick, id: \.self) { id in
                quickButton(id)
                    .editable(editMode, id: "q:" + id,
                              onRemove: { withAnimation { store.home.quick.removeAll { $0 == id } } },
                              onDrop: { d in moveQuick(d, before: id) })
            }
            if editMode && store.home.quick.count < HomeLayout.maxQuick {
                AddTile(size: 52) { addingQuick = true }
            }
        }
        .card()
    }

    private func moveQuick(_ dragged: String, before target: String) {
        guard dragged.hasPrefix("q:") else { return }
        let d = String(dragged.dropFirst(2))
        var q = store.home.quick
        guard let from = q.firstIndex(of: d) else { return }
        q.remove(at: from)
        q.insert(d, at: q.firstIndex(of: target) ?? q.count)
        withAnimation { store.home.quick = q }
    }

    @ViewBuilder
    private func quickButton(_ id: String) -> some View {
        switch id {
        case "screen":
            KeyButton(symbol: store.state.screenOff == true ? "tv" : "tv.slash", label: store.state.screenOff == true ? "Screen on" : "Screen off",
                      size: 52, filled: store.state.screenOff == true) {
                store.perform(.screen(store.state.screenOff == true))
            }
        case "type":
            KeyButton(symbol: "keyboard", label: "Type", size: 52) { showKeyboard = true }
                .disabled(!store.tv.hasWiFi)
        case "playpause":
            let b = KeyButton(symbol: "playpause.fill", label: "Play/Pause", size: 52) {
                if cast.status.media != nil { cast.playPause() } else { store.press(store.state.input == "Apps" ? "Pause" : "Play") }
            }
            if editMode {
                b
            } else {
                b.contextMenu {
                    Button { store.press("Play") } label: { Label("Play", systemImage: "play.fill") }
                    Button { store.press("Pause") } label: { Label("Pause", systemImage: "pause.fill") }
                }
            }
        default:
            let b = KeyButton(symbol: Keys.def(id)?.symbol, label: Keys.label(id), size: 52, tint: RemoteFace.tint(id),
                              badge: store.codes[id] != nil) { store.press(id) }
            if editMode {
                b
            } else {
                b.contextMenu { RouteMenu(store: store, key: id) }
            }
        }
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

    private var visibleApps: [BraviaApp] {
        store.home.ordered(store.apps.filter { !store.home.hiddenApps.contains($0.uri) }, id: \.uri)
    }

    private var visibleSide: [SideApp] {
        store.home.ordered(store.sideApps.filter { !store.home.hiddenApps.contains("side:" + $0.package) }, id: { "side:" + $0.package })
    }

    private func dropApp(_ dragged: String, before target: String) {
        guard dragged.hasPrefix("a:") else { return }
        let ids = visibleApps.map(\.uri) + visibleSide.map { "side:" + $0.package }
        withAnimation { store.home.moveApp(String(dragged.dropFirst(2)), before: target, visible: ids) }
    }

    private func hideApp(_ id: String) {
        withAnimation { store.home.hiddenApps.append(id) }
    }

    private var appsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Apps")
            if store.apps.isEmpty {
                Text(store.tv.hasWiFi ? "The app list loads once the TV is on." : "Apps need the TV on Wi-Fi. Netflix and YouTube still work over IR from the remote page.")
                    .font(.callout).foregroundStyle(.secondary)
                    .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 12)], spacing: 14) {
                    ForEach(visibleApps) { a in
                        let tile = Button { store.open(a) } label: { AppTile(app: a) }.buttonStyle(PressStyle())
                        Group {
                            if editMode {
                                tile
                            } else {
                                tile.contextMenu {
                                    Button(role: .destructive) { hideApp(a.uri) } label: { Label("Hide", systemImage: "eye.slash") }
                                }
                            }
                        }
                        .editable(editMode, id: "a:" + a.uri, onRemove: { hideApp(a.uri) }, onDrop: { d in dropApp(d, before: a.uri) })
                    }
                }
            }
        }
    }

    @State private var renaming: SideApp?
    @State private var newName = ""

    @ViewBuilder
    private var sideApps: some View {
        if !store.sideApps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "Sideloaded")
                    Spacer()
                    if store.adbBusy { ProgressView().controlSize(.small) }
                    Button { Task { await store.loadSideApps() } } label: { Image(systemName: "arrow.clockwise") }
                        .font(.caption.weight(.bold))
                        .disabled(store.adbBusy)
                    Button { addingApp = true } label: { Image(systemName: "plus") }
                        .font(.caption.weight(.bold))
                        .padding(.leading, 10)
                }
                if store.adbBusy, let m = store.adbMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 12)], spacing: 14) {
                    ForEach(visibleSide) { a in
                        let id = "side:" + a.package
                        let tile = Button { store.open(a) } label: { SideTile(app: a) }.buttonStyle(PressStyle())
                        Group {
                            if editMode {
                                tile
                            } else {
                                tile.contextMenu {
                                    Button { newName = a.title; renaming = a } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { hideApp(id) } label: { Label("Hide", systemImage: "eye.slash") }
                                    Text(a.package)
                                }
                            }
                        }
                        .editable(editMode, id: "a:" + id, onRemove: { hideApp(id) }, onDrop: { d in dropApp(d, before: id) })
                    }
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let r = renaming { store.rename(r, newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        } else if store.tv.hasWiFi {
            Button { Task { await store.loadSideApps() } } label: {
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show sideloaded apps").font(.subheadline.weight(.semibold))
                        Text(store.adbMessage ?? "Over ADB. Needs USB debugging on in the TV's Developer options.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if store.adbBusy { ProgressView() }
                }
                .foregroundStyle(.white)
            }
            .disabled(store.adbBusy)
            .card()
            Button { addingApp = true } label: {
                Label("Add any app, system apps too", systemImage: "plus.app").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 4)
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

/// One shape for every app icon, iOS style: a continuous-corner square at the same radius ratio as iOS icons.
struct IconMask: Shape {
    func path(in r: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(r.width, r.height) * IconShape.corner, style: .continuous).path(in: r)
    }
}

struct AppTile: View {
    let app: BraviaApp
    @ObservedObject private var icons = IconCache.shared

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = icons.image(app.uri, url: app.iconURL) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: Apps.symbol(app.title)).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 62, height: 62)
            .clipShape(IconMask())
            .overlay(IconMask().stroke(Theme.stroke))
            Text(app.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Every package on the TV, searchable. Pick any to put it on the home page.
struct AddAppSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var third: [String] = []
    @State private var system: [String] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var showSystem = false

    private var list: [String] {
        let base = showSystem ? system : third
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter { $0.lowercased().contains(q) || name($0).lowercased().contains(q) }
    }

    private func name(_ pkg: String) -> String {
        store.sideApps.first { $0.package == pkg }?.title ?? SideApp.guessName(pkg)
    }

    private func added(_ pkg: String) -> Bool {
        store.sideApps.contains { $0.package == pkg } && !store.home.hiddenApps.contains("side:" + pkg)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                List {
                    Picker("", selection: $showSystem) {
                        Text("Installed (\(third.count))").tag(false)
                        Text("System (\(system.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    if loading {
                        HStack { ProgressView(); Text("Asking the TV…").foregroundStyle(.secondary) }
                    }
                    if let error { Text(error).foregroundStyle(Theme.danger) }
                    ForEach(list, id: \.self) { pkg in
                        Button {
                            if added(pkg) {
                                store.home.hiddenApps.append("side:" + pkg)
                            } else {
                                store.addSideApp(pkg)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if let d = store.sideApps.first(where: { $0.package == pkg })?.iconData, let img = UIImage(data: d) {
                                    Image(uiImage: img).resizable().frame(width: 32, height: 32).clipShape(IconMask())
                                } else {
                                    Image(systemName: "app.dashed").font(.system(size: 22)).frame(width: 32, height: 32).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name(pkg)).foregroundStyle(.white)
                                    Text(pkg).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: added(pkg) ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(added(pkg) ? Theme.accent : .secondary)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $search, prompt: "Search apps or packages")
            }
            .navigationTitle("Add apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                do {
                    let r = try await store.allPackages()
                    third = r.third
                    system = r.system
                } catch {
                    self.error = error.localizedDescription
                }
                loading = false
            }
        }
    }
}

/// A sideloaded app: no icon comes over ADB, so a neon monogram stands in.
struct SideTile: View {
    let app: SideApp

    private var hue: Double {
        Double(app.package.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
    }

    var body: some View {
        VStack(spacing: 6) {
            if let d = app.iconData, let img = UIImage(data: d) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(IconMask())
                    .overlay(IconMask().stroke(Theme.stroke))
            } else {
                monogram
            }
            Text(app.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var monogram: some View {
            ZStack {
                IconMask().fill(Color.black)
                IconMask()
                    .stroke(Color(hue: hue, saturation: 0.75, brightness: 1), lineWidth: 2)
                    .shadow(color: Color(hue: hue, saturation: 0.8, brightness: 1).opacity(0.8), radius: 6)
                Text(String(app.title.prefix(1)).uppercased())
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 1))
                    .shadow(color: Color(hue: hue, saturation: 0.8, brightness: 1), radius: 8)
            }
            .frame(width: 62, height: 62)
    }
}

/// Long-press menu on a remote button: pick the path for this one press.
struct RouteMenu: View {
    @ObservedObject var store: Store
    let key: String

    var body: some View {
        Button { store.press(key, via: .wifi) } label: { Label("Send over Wi-Fi", systemImage: "wifi") }
            .disabled(!store.tv.hasWiFi)
        Button { store.press(key, via: .ir) } label: { Label("Send over IR", systemImage: "dot.radiowaves.right") }
            .disabled(!store.blaster.isReady)
        if store.blaster.isReady {
            Button { store.startLearn(key) } label: { Label("Learn from remote", systemImage: "record.circle") }
        }
        if store.codes[key] != nil {
            Button(role: .destructive) { store.codes[key] = nil } label: { Label("Forget learned code", systemImage: "trash") }
        }
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
