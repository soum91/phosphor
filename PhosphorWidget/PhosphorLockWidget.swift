import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct PhosphorLockEntry: TimelineEntry {
    var date: Date
    var state: TVState
    var name: String
    var icon: String { state.power == true ? "tv.fill" : "tv" }
    var short: String { state.power == nil ? "--" : (state.power == true ? "On" : "Off") }
    var title: String { name }
    var headline: String { state.power == nil ? "Open Obsidian" : (state.power == true ? (state.input ?? "On") : "Off") }
    var detail: String { state.power == true ? (state.volume.map { "Volume \($0)" + (state.muted == true ? " · muted" : "") } ?? "") : "" }
    static func make() -> PhosphorLockEntry { .init(date: .now, state: .stored, name: TVConfig.stored.name) }
}

struct PhosphorLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhosphorLockEntry { PhosphorLockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (PhosphorLockEntry) -> Void) { completion(PhosphorLockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhosphorLockEntry>) -> Void) {
        completion(Timeline(entries: [PhosphorLockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct PhosphorLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ObsidianLockStatusV1", provider: PhosphorLockProvider()) { entry in
            PhosphorLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("TV status")
        .description("TV power, input and volume. Tap to open Obsidian.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct PhosphorLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhosphorLockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
