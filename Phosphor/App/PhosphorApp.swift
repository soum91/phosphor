import SwiftUI
import BackgroundTasks
import WidgetKit
import AppIntents

@main
struct PhosphorApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase
    static let refreshID = "com.soum91.phosphor.refresh"

    init() {
        PhosphorShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background(VolumeHUDHider().frame(width: 1, height: 1).opacity(0.01))
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            switch newPhase {
            case .active:
                store.startPolling()
                if store.blaster.isReady, !store.blasterState.isConnected { store.connectBlaster() }
                store.updateVolumeButtons(active: true)
            case .inactive:
                store.updateVolumeButtons(active: false)
            case .background:
                store.updateVolumeButtons(active: false)
                store.stopPolling()
                Task { await IRSender.shared.drop() }
                Self.scheduleRefresh()
                PhosphorShortcuts.updateAppShortcutParameters()
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            Self.scheduleRefresh()
            await TV.refresh()
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}

/// Siri phrases. These work with no setup: "Hey Siri, TV off in Obsidian".
struct PhosphorShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TVOffIntent(), phrases: [
            "TV off in \(.applicationName)",
            "Turn off the TV in \(.applicationName)",
            "\(.applicationName) off",
        ], shortTitle: "TV Off", systemImageName: "power")
        AppShortcut(intent: TVOnIntent(), phrases: [
            "TV on in \(.applicationName)",
            "Turn on the TV in \(.applicationName)",
            "\(.applicationName) on",
        ], shortTitle: "TV On", systemImageName: "tv.fill")
        AppShortcut(intent: VolumeUpIntent(), phrases: [
            "Turn it up in \(.applicationName)",
            "\(.applicationName) louder",
        ], shortTitle: "Volume Up", systemImageName: "speaker.plus.fill")
        AppShortcut(intent: VolumeDownIntent(), phrases: [
            "Turn it down in \(.applicationName)",
            "\(.applicationName) quieter",
        ], shortTitle: "Volume Down", systemImageName: "speaker.minus.fill")
        AppShortcut(intent: MuteIntent(), phrases: [
            "Mute \(.applicationName)",
            "Mute the TV in \(.applicationName)",
        ], shortTitle: "Mute", systemImageName: "speaker.slash.fill")
        AppShortcut(intent: LaunchAppIntent(), phrases: [
            "Open \(\.$app) in \(.applicationName)",
            "\(.applicationName) \(\.$app)",
            "Put on \(\.$app) in \(.applicationName)",
        ], shortTitle: "Open App", systemImageName: "app.fill")
        AppShortcut(intent: RunPresetIntent(), phrases: [
            "Run \(\.$preset) in \(.applicationName)",
            "Set \(.applicationName) to \(\.$preset)",
        ], shortTitle: "Run Preset", systemImageName: "sparkles")
        AppShortcut(intent: SetInputIntent(), phrases: [
            "Switch \(.applicationName) to \(\.$input)",
            "\(.applicationName) input \(\.$input)",
        ], shortTitle: "Set Input", systemImageName: "rectangle.portrait.and.arrow.forward")
        AppShortcut(intent: ScreenIntent(on: false), phrases: [
            "Screen off in \(.applicationName)",
            "Turn the screen off in \(.applicationName)",
        ], shortTitle: "Screen Off", systemImageName: "tv.slash")
    }
}
