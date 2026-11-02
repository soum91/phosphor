import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Two ways in, use both. Wi-Fi gives you everything (exact volume, apps, inputs, picture settings, what's on). IR wakes the TV when its network side is asleep and keeps working when Wi-Fi doesn't.")
                            .foregroundStyle(.secondary)
                        NavigationLink { FindTVView() } label: {
                            step(1, "TV on Wi-Fi", store.tv.hasWiFi ? "\(store.tv.name) at \(store.tv.host)" : "Find it on your network", done: store.tv.hasWiFi)
                        }
                        NavigationLink { BlasterSetupView() } label: {
                            step(2, "Tuya IR blaster", store.blaster.isReady ? "\(store.blaster.name ?? "Blaster") · \(store.blasterState.text)" : "The one Redshift and Subwave use", done: store.blaster.isReady)
                        }
                        if store.isSetUp {
                            Button { dismiss() } label: {
                                Text("Done").fontWeight(.semibold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Set up")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ title: String, _ sub: String, done: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? Theme.accent : .white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
        }
        .card()
    }
}

// MARK: - Find the TV

struct FindTVView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = TVFinder()
    @State private var host = ""
    @State private var psk = ""
    @State private var kind: TVKind = .sony
    @State private var friendlyName = ""
    @State private var model: String?
    @State private var awaitingCode = false
    @State private var pairingCode = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    if finder.found.isEmpty {
                        HStack {
                            if finder.searching { ProgressView().padding(.trailing, 6) }
                            Text(finder.searching ? "Looking for TVs…" : "Nothing found. Type the IP below (TV: Settings › Network & Internet › your network, or your router).")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(finder.found) { f in
                        Button {
                            host = f.host
                            friendlyName = f.name
                            model = f.model
                            kind = f.isBravia ? .sony : .android
                            awaitingCode = false
                            message = nil
                        } label: {
                            HStack {
                                Image(systemName: f.isBravia ? "tv.fill" : "tv")
                                    .foregroundStyle(f.isBravia ? Theme.accent : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(f.name).foregroundStyle(.white)
                                    Text([f.model, f.host, f.isBravia ? "Sony IP control" : (f.supportsAndroidRemote ? "Android TV Remote" : "Cast (try pairing)")].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if host == f.host { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    HStack { Text("On your Wi-Fi"); Spacer(); Button("Search again") { finder.start() }.font(.caption) }
                }

                Section {
                    Picker("Control protocol", selection: $kind) {
                        ForEach(TVKind.allCases, id: \.self) { type in Text(type.title).tag(type) }
                    }
                    TextField("TV IP, e.g. 192.168.1.40", text: $host)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                    TextField("Name (optional)", text: $friendlyName)
                    if kind == .sony {
                        SecureField("Pre-shared key", text: $psk)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task {
                                busy = true
                                message = nil
                                if let err = await store.connectTV(host: host, psk: psk) {
                                    message = err
                                } else {
                                    if !friendlyName.isEmpty { store.tv.name = friendlyName }
                                    dismiss()
                                }
                                busy = false
                            }
                        } label: {
                            HStack { Text("Connect Sony TV").fontWeight(.semibold); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(host.isEmpty || busy)
                    } else if !awaitingCode {
                        Button {
                            Task {
                                busy = true
                                message = nil
                                do {
                                    try await AndroidTVTransport.shared.startPairing(host: host)
                                    awaitingCode = true
                                } catch { message = error.localizedDescription }
                                busy = false
                            }
                        } label: {
                            HStack { Text("Pair Android / Google TV").fontWeight(.semibold); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(host.isEmpty || busy)
                    } else {
                        Text("Enter the code now displayed on the TV.")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("Six-character pairing code", text: $pairingCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button {
                            Task {
                                busy = true
                                message = nil
                                do {
                                    try await AndroidTVTransport.shared.finishPairing(host: host, code: pairingCode)
                                    store.addAndroidTV(host: host, name: friendlyName, model: model)
                                    dismiss()
                                } catch {
                                    message = error.localizedDescription
                                    awaitingCode = false
                                }
                                busy = false
                            }
                        } label: {
                            HStack { Text("Finish pairing").fontWeight(.semibold); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(pairingCode.count != 6 || busy)
                    }
                } header: {
                    Text(kind == .sony ? "Address and key" : "Address and pairing")
                } footer: {
                    Text(kind == .sony ? "Use the same key as Afterglow and Subwave." : "No Sony key, ADB debugging or Google account required. Confirm the code shown on your TV.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(message.hasPrefix("Connected") ? Theme.accent : Theme.danger) }
                }

                Section {
                    if kind == .sony {
                        Label("Settings › Network & Internet › Home network › IP control › Authentication: **Normal and Pre-Shared Key**, then set a **Pre-Shared Key**.", systemImage: "1.circle")
                        Label("Same menu: turn **Simple IP control** on if you see it.", systemImage: "2.circle")
                        Label("Settings › Network & Internet › **Remote start** on.", systemImage: "3.circle")
                    } else {
                        Label("Leave the TV on and connected to your home network.", systemImage: "1.circle")
                        Label("Android TV Remote Service must be enabled. The TV should show a code after you tap Pair.", systemImage: "2.circle")
                        Label("If pairing doesn't appear, check your network isolation and try the TV's current IP.", systemImage: "3.circle")
                    }
                    Label("A DHCP reservation in your router keeps the TV's IP stable.", systemImage: "4.circle")
                } header: {
                    Text(kind == .sony ? "On the Sony TV" : "On the Android / Google TV")
                }
                .font(.callout)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Add TV")
        .onAppear {
            finder.start()
        }
        .onDisappear { finder.stop() }
    }
}

// MARK: - IR blaster

struct BlasterSetupView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.blaster.hasKey {
                BlasterStatusView()
            } else if store.token != nil {
                BlasterPickerView()
            } else {
                LoginView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("I have the key") { ManualKeyView() }
                        }
                    }
            }
        }
        .navigationTitle("IR blaster")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BlasterPickerView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    if store.loadingDevices {
                        HStack { ProgressView(); Text("Loading your devices…").foregroundStyle(.secondary) }
                    }
                    ForEach(store.devices) { d in
                        Button { store.choose(d) } label: {
                            HStack {
                                Image(systemName: d.isBlaster ? "dot.radiowaves.right" : "circle.dotted")
                                    .foregroundStyle(d.isBlaster ? Theme.accent : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(d.name).foregroundStyle(.white)
                                    Text(d.productName.isEmpty ? d.category : d.productName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !d.online { Text("offline").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Pick the IR blaster")
                } footer: {
                    Text("Obsidian saves its local key and talks to it over Wi-Fi from here on, same as Redshift and Subwave.")
                }
                if let e = store.setupError { Section { Text(e).foregroundStyle(Theme.danger) } }
                Section { Button("Sign out of Smart Life", role: .destructive) { store.signOutCloud() } }
            }
            .scrollContentBackground(.hidden)
        }
        .task { if store.devices.isEmpty { await store.loadDevices() } }
    }
}

struct BlasterStatusView: View {
    @EnvironmentObject var store: Store
    @State private var host = ""

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    HStack {
                        Text(store.blaster.name ?? "IR blaster")
                        Spacer()
                        if store.blasterState.isBusy { ProgressView() }
                    }
                    Text(store.blasterState.text)
                        .font(.callout)
                        .foregroundStyle(store.blasterState.isConnected ? Theme.accent : (store.blasterState == .off ? .secondary : Theme.danger))
                    if !store.blasterLog.isEmpty {
                        DisclosureGroup("What each device said") {
                            ForEach(store.blasterLog, id: \.self) { line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if let h = store.blaster.host { LabeledContent("IP", value: h) }
                    LabeledContent("Command format", value: store.blaster.format.title)
                }
                Section {
                    Button("Find it on Wi-Fi again") { store.findBlaster() }
                    HStack {
                        TextField("Blaster IP", text: $host).keyboardType(.decimalPad)
                        Button("Use") { store.setBlasterHost(host) }.disabled(host.isEmpty)
                    }
                    Button("Reconnect") { store.connectBlaster() }
                    Button("Test: send Power on") { store.testIR("WakeUp") }
                }
                Section {
                    Picker("Command format", selection: Binding(get: { store.blaster.forced }, set: { store.blaster.forced = $0 })) {
                        Text("Automatic").tag(IRFormat?.none)
                        ForEach(IRFormat.allCases) { Text($0.title).tag(IRFormat?.some($0)) }
                    }
                    if store.token != nil {
                        Button("Refresh local key from Smart Life") { Task { await store.refreshKey() } }
                    }
                } footer: {
                    Text("Only change the format if buttons do nothing. Refresh the key if you re-paired the blaster in Smart Life.")
                }
                Section { Button("Forget blaster", role: .destructive) { store.forgetBlaster() } }
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            host = store.blaster.host ?? ""
            if store.blaster.isReady && !store.blasterState.isConnected && !store.blasterState.isBusy { store.connectBlaster() }
        }
    }
}

struct ManualKeyView: View {
    @EnvironmentObject var store: Store
    @State private var devId = ""
    @State private var key = ""
    @State private var host = ""

    var body: some View {
        ZStack {
            Theme.background()
            Form {
                Section {
                    TextField("Device ID", text: $devId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Local key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IP (optional, else it scans)", text: $host).keyboardType(.decimalPad)
                } footer: {
                    Text("From tinytuya, Home Assistant, or Redshift's or Subwave's settings.")
                }
                Button("Save") {
                    store.setBlaster(devId: devId.trimmingCharacters(in: .whitespaces), key: key.trimmingCharacters(in: .whitespaces),
                                     name: "IR blaster", host: host.trimmingCharacters(in: .whitespaces))
                }
                .disabled(devId.isEmpty || key.isEmpty)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Enter key")
    }
}
