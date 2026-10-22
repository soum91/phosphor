import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var confirmReboot = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                List {
                    Section("TV") {
                        NavigationLink { FindTVView() } label: {
                            LabeledContent("Wi-Fi", value: store.tv.hasWiFi ? store.tv.host : "Not set")
                        }
                        if store.tv.hasWiFi {
                            TextField("Name", text: $store.tv.name)
                            if let m = store.tv.model { LabeledContent("Model", value: m) }
                            if let mac = store.tv.mac, !mac.isEmpty { LabeledContent("MAC", value: mac) }
                            LabeledContent("Buttons reported", value: "\(store.remote.count)")
                        }
                        Picker("Send commands", selection: $store.tv.route) {
                            ForEach(TVRoute.allCases) { Text($0.title).tag($0) }
                        }
                        if store.tv.hasWiFi {
                            Button("Restart the TV") { confirmReboot = true }
                            Button("Forget TV", role: .destructive) { confirmForget = true }
                        }
                    }

                    Section {
                        NavigationLink { BlasterSetupView() } label: {
                            LabeledContent("Blaster", value: store.blaster.isReady ? (store.blaster.name ?? "Set") : "Not set")
                        }
                        if store.blaster.isReady {
                            LabeledContent("Status", value: store.blasterState.text)
                            LabeledContent("Learned buttons", value: "\(store.codes.count)")
                        }
                    } header: {
                        Text("IR blaster")
                    } footer: {
                        Text("Wi-Fi, then IR: tries Sony IP control first and falls back to the blaster when the TV doesn't answer. Power on and off use Sony's separate on/off codes over IR, so it never toggles the wrong way.")
                    }

                    Section("Presets") {
                        NavigationLink { PresetListView() } label: { LabeledContent("Presets", value: "\(store.presets.count)") }
                    }

                    Section {
                        LabeledContent("Version", value: AppGroup.version + " (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        LabeledContent("Widget data", value: AppGroup.isShared ? "Shared" : "Not shared")
                        if !AppGroup.isShared {
                            Text("The sideload stripped the App Group, so the widgets and Control Center can't see the TV. Reinstall with app extensions kept.")
                                .font(.caption).foregroundStyle(Theme.danger)
                        }
                        Link("Source on GitHub", destination: URL(string: "https://github.com/soum91/phosphor")!)
                    } header: {
                        Text("About")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget \(store.tv.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { store.forgetTV() }
            }
            .confirmationDialog("Restart \(store.tv.name)?", isPresented: $confirmReboot, titleVisibility: .visible) {
                Button("Restart", role: .destructive) {
                    Task {
                        do { try await Bravia(store.tv)?.reboot(); store.show("Restarting the TV") } catch { store.show(error.localizedDescription) }
                    }
                }
            }
        }
    }
}

// MARK: - Presets

struct PresetListView: View {
    @EnvironmentObject var store: Store
    @State private var editing: TVPreset?

    var body: some View {
        ZStack {
            Theme.background()
            List {
                ForEach(store.presets) { p in
                    Button { editing = p } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.icon).foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.white)
                                Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { idx in store.presets.remove(atOffsets: idx) }
                .onMove { from, to in store.presets.move(fromOffsets: from, toOffset: to) }
                Button { editing = TVPreset(name: "New preset", icon: "sparkles") } label: { Label("Add preset", systemImage: "plus") }
                Button("Restore default presets") { store.presets = TVPreset.defaults }.foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Presets")
        .toolbar { EditButton() }
        .sheet(item: $editing) { p in PresetEditor(preset: p).environmentObject(store) }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var preset: TVPreset
    @State private var useVolume = false

    private static let icons = ["sparkles", "tv", "film", "n.square.fill", "play.rectangle.fill", "music.note", "gamecontroller",
                                "moon.stars.fill", "sun.max.fill", "sportscourt.fill", "party.popper.fill", "bed.double.fill", "power"]
    private static let buttonKeys = ["Home", "Return", "Confirm", "Play", "Pause", "SubTitle", "ClosedCaption", "Audio", "Wide",
                                     "ActionMenu", "Mute", "Options"]

    struct Choice: Identifiable { let id: String; let name: String }

    private var inputChoices: [Choice] {
        if !store.inputs.isEmpty { return store.inputs.map { Choice(id: $0.uri, name: $0.name) } }
        return Keys.builtin.filter { $0.group == .inputs && $0.id != "Input" }.map { Choice(id: $0.id, name: $0.label) }
    }

    private var appChoices: [Choice] {
        if !store.apps.isEmpty { return store.apps.map { Choice(id: $0.uri, name: $0.title) } }
        return ["Netflix", "YouTube", "Prime Video", "Disney+", "Spotify"].map { Choice(id: $0, name: $0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                Form {
                    Section {
                        TextField("Name", text: $preset.name)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Self.icons, id: \.self) { i in
                                    Image(systemName: i)
                                        .frame(width: 38, height: 38)
                                        .background(preset.icon == i ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                                        .foregroundStyle(preset.icon == i ? .black : .white)
                                        .onTapGesture { preset.icon = i }
                                }
                            }
                        }
                        Toggle("Turns the TV on", isOn: $preset.powerOn).tint(Theme.accent)
                    }
                    if preset.powerOn {
                        Section("Then") {
                            Picker("Input", selection: $preset.input) {
                                Text("Leave as is").tag(String?.none)
                                ForEach(inputChoices) { i in Text(i.name).tag(String?.some(i.id)) }
                                if let cur = preset.input, !inputChoices.contains(where: { $0.id == cur }) {
                                    Text(Inputs.label(cur)).tag(String?.some(cur))
                                }
                            }
                            Picker("App", selection: $preset.app) {
                                Text("None").tag(String?.none)
                                ForEach(appChoices) { a in Text(a.name).tag(String?.some(a.id)) }
                                if let cur = preset.app, !appChoices.contains(where: { $0.id == cur }) {
                                    Text(Apps.label(cur)).tag(String?.some(cur))
                                }
                            }
                            Toggle("Screen off (keeps playing)", isOn: $preset.screenOff).tint(Theme.accent)
                        }
                        Section {
                            Toggle("Set volume", isOn: $useVolume).tint(Theme.accent)
                            if useVolume {
                                HStack {
                                    Slider(value: Binding(get: { Double(preset.volume ?? 15) }, set: { preset.volume = Int($0) }),
                                           in: 0...Double(store.state.maxVolume ?? 100), step: 1)
                                    Text("\(preset.volume ?? 15)").monospacedDigit().frame(width: 34)
                                }
                            }
                        } footer: {
                            Text("Exact volume needs Wi-Fi.")
                        }
                        Section("Buttons to press, in order") {
                            ForEach(Self.buttonKeys, id: \.self) { k in
                                Toggle(Keys.label(k), isOn: Binding(
                                    get: { preset.keys.contains(k) },
                                    set: { on in
                                        preset.keys.removeAll { $0 == k }
                                        if on { preset.keys.append(k) }
                                    }))
                                .tint(Theme.accent)
                            }
                        }
                    }
                    if store.presets.contains(where: { $0.id == preset.id }) {
                        Section {
                            Button("Delete preset", role: .destructive) { store.deletePreset(preset.id); dismiss() }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !useVolume { preset.volume = nil }
                        store.savePreset(preset)
                        dismiss()
                    }
                }
            }
            .onAppear { useVolume = preset.volume != nil }
        }
    }
}
