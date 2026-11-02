import Foundation

/// One snapshot per television. The existing App Group files remain a projection of the
/// active profile, so older widgets, intents and the original Sony controller keep working.
struct TVProfile: Codable, Identifiable {
    var id: String
    var config: TVConfig
    var state: TVState
    var inputs: [BraviaInput]
    var apps: [BraviaApp]
    var remote: [String: String]
    var learnedCodes: [String: String]
    var sideApps: [SideApp]
    var presets: [TVPreset]
    var remoteLayout: RemoteLayout
    var homeLayout: HomeLayout

    static func current(id: String, store: Store) -> TVProfile {
        TVProfile(id: id, config: store.tv, state: store.state, inputs: store.inputs,
                  apps: store.apps, remote: store.remote, learnedCodes: store.codes, sideApps: store.sideApps,
                  presets: store.presets, remoteLayout: store.layout, homeLayout: store.home)
    }

    static func initial(id: String = UUID().uuidString, config: TVConfig) -> TVProfile {
        let genericApps: [BraviaApp] = [
            BraviaApp(uri: "https://www.youtube.com", title: "YouTube", icon: nil),
            BraviaApp(uri: "https://www.netflix.com", title: "Netflix", icon: nil),
            BraviaApp(uri: "https://open.spotify.com", title: "Spotify", icon: nil),
            BraviaApp(uri: "https://www.primevideo.com", title: "Prime Video", icon: nil),
        ]
        let genericPresets: [TVPreset] = [
            TVPreset(name: "YouTube", icon: "play.rectangle.fill", app: "YouTube"),
            TVPreset(name: "Netflix", icon: "n.square.fill", app: "Netflix"),
            TVPreset(name: "Off", icon: "power", powerOn: false),
        ]
        let genericRemote = RemoteLayout(blocks: [
            .row(["Settings", "Tv", "Input"]),
            RemoteBlock(kind: .dpad),
            .row(["Return", "Home", "Options"]),
            RemoteBlock(kind: .rockers),
            .row(["Rewind", "Play", "Pause", "Forward"]),
            .row(["Prev", "Stop", "Next"]),
            .row(["Red", "Green", "Yellow", "Blue"]),
        ])
        return TVProfile(id: id, config: config, state: TVState(), inputs: [],
                         apps: config.kind == .android ? genericApps : [], remote: [:], learnedCodes: [:],
                         sideApps: [], presets: config.kind == .android ? genericPresets : TVPreset.defaults,
                         remoteLayout: config.kind == .android ? genericRemote : .standard,
                         homeLayout: HomeLayout())
    }

    /// Captures all of the pre-multi-TV data once, without changing or deleting any legacy file.
    static func legacy(id: String, config: TVConfig) -> TVProfile {
        TVProfile(id: id, config: config, state: TVState.stored, inputs: InputCache.load(),
                  apps: AppCache.load(), remote: RemoteCodes.load(), learnedCodes: LearnedCodes.load(), sideApps: SideAppStore.load(),
                  presets: PresetStore.load(), remoteLayout: RemoteLayout.stored,
                  homeLayout: HomeLayout.stored)
    }

    func activate() {
        TVConfig.stored = config
        TVState.stored = state
        InputCache.save(inputs)
        AppCache.save(apps)
        RemoteCodes.save(remote)
        LearnedCodes.save(learnedCodes)
        SideAppStore.save(sideApps)
        PresetStore.save(presets)
        RemoteLayout.stored = remoteLayout
        HomeLayout.stored = homeLayout
    }
}

struct TVDirectory: Codable {
    var selected: String?
    var devices: [TVProfile]

    static func load() -> TVDirectory {
        if let saved = AppGroup.read(TVDirectory.self, "tv-profiles.json") { return saved }
        let legacy = TVConfig.stored
        let previous = legacy.hasWiFi ? TVProfile.legacy(id: UUID().uuidString, config: legacy) : nil
        let initial = TVDirectory(selected: previous?.id, devices: previous.map { [$0] } ?? [])
        save(initial)
        return initial
    }

    static func save(_ directory: TVDirectory) {
        AppGroup.write(directory, "tv-profiles.json")
    }
}
