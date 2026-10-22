import SwiftUI

/// The home page, as you arranged it: section order, hidden sections, the quick buttons, and app order.
struct HomeLayout: Codable, Equatable {
    enum Section: String, Codable, CaseIterable, Identifiable {
        case power, quick, inputs, presets, nowPlaying, apps, sideloaded, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .power: return "Power and volume"
            case .quick: return "Quick buttons"
            case .inputs: return "Inputs"
            case .presets: return "Presets"
            case .nowPlaying: return "Now casting"
            case .apps: return "Apps"
            case .sideloaded: return "Sideloaded apps"
            case .settings: return "Picture, sound, remote"
            }
        }
    }

    static let maxQuick = 10
    static let defaultQuick = ["screen", "Tv", "Home", "Return", "type", "playpause"]

    var order: [Section] = Section.allCases
    var hidden: [Section] = []
    var quick: [String] = HomeLayout.defaultQuick
    /// App ids in your order (Sony app URIs, or "side:<package>"); anything new goes after these.
    var appOrder: [String] = []
    var hiddenApps: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? c.decodeIfPresent([String].self, forKey: .order))?.compactMap { Section(rawValue: $0) } ?? Section.allCases
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden))?.compactMap { Section(rawValue: $0) } ?? []
        quick = (try? c.decodeIfPresent([String].self, forKey: .quick)) ?? HomeLayout.defaultQuick
        appOrder = (try? c.decodeIfPresent([String].self, forKey: .appOrder)) ?? []
        hiddenApps = (try? c.decodeIfPresent([String].self, forKey: .hiddenApps)) ?? []
    }

    /// Every section, in your order (new ones added in later versions land at the end).
    var sections: [Section] { order + Section.allCases.filter { !order.contains($0) } }

    func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
        let rank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (rank[id($0.element)] ?? 100_000 + $0.offset) < (rank[id($1.element)] ?? 100_000 + $1.offset) }
            .map(\.element)
    }

    /// Puts `dragged` right before `target` in the app order (seeding it from what's on screen).
    mutating func moveApp(_ dragged: String, before target: String, visible: [String]) {
        var list = appOrder
        for v in visible where !list.contains(v) { list.append(v) }
        list.removeAll { $0 == dragged }
        let i = list.firstIndex(of: target) ?? list.count
        list.insert(dragged, at: i)
        appOrder = list
    }

    mutating func moveSection(_ s: Section, by delta: Int) {
        var list = sections
        guard let i = list.firstIndex(of: s) else { return }
        let j = max(0, min(list.count - 1, i + delta))
        list.remove(at: i)
        list.insert(s, at: j)
        order = list
    }

    static var stored: HomeLayout {
        get {
            guard let d = UserDefaults.standard.data(forKey: "homeLayout"), let l = try? JSONDecoder().decode(HomeLayout.self, from: d) else { return HomeLayout() }
            return l
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "homeLayout") }
    }
}

/// What a quick-row item is: a few app actions, otherwise any remote button.
enum QuickItem {
    static let specials = ["screen", "type", "playpause"]

    static func label(_ id: String) -> String {
        switch id {
        case "screen": return "Screen off"
        case "type": return "Type"
        case "playpause": return "Play/Pause"
        default: return Keys.label(id)
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "screen": return "tv.slash"
        case "type": return "keyboard"
        case "playpause": return "playpause.fill"
        default: return Keys.def(id)?.symbol ?? "circle.grid.3x3.fill"
        }
    }
}

// MARK: - Edit mode look and feel

/// The iOS home screen wiggle.
struct Jiggle: ViewModifier {
    let on: Bool
    @State private var tilt = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on ? (tilt ? 1.8 : -1.8) : 0))
            .animation(on ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .easeOut(duration: 0.1), value: tilt)
            .onAppear { if on { tilt = true } }
            .onChange(of: on) { _, v in tilt = v }
    }
}

/// In edit mode: wiggles, swallows taps, shows a remove badge, and can be dragged onto another item to move it there.
struct EditableItem: ViewModifier {
    let editing: Bool
    let id: String
    var removeSymbol = "minus.circle.fill"
    let onRemove: () -> Void
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if editing {
            content
                .overlay(Color.white.opacity(0.001).onTapGesture {})
                .overlay(alignment: .topLeading) {
                    Button(action: onRemove) {
                        Image(systemName: removeSymbol)
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(red: 1, green: 0.3, blue: 0.35))
                            .background(Circle().fill(.black).padding(2))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                }
                .modifier(Jiggle(on: true))
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let d = items.first, d != id else { return false }
                    onDrop(d)
                    return true
                }
        } else {
            content
        }
    }
}

extension View {
    func editable(_ editing: Bool, id: String, removeSymbol: String = "minus.circle.fill",
                  onRemove: @escaping () -> Void, onDrop: @escaping (String) -> Void) -> some View {
        modifier(EditableItem(editing: editing, id: id, removeSymbol: removeSymbol, onRemove: onRemove, onDrop: onDrop))
    }
}

/// The "+" tile shown at the end of an editable row.
struct AddTile: View {
    var size: CGFloat = 52
    var label = "Add"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .frame(width: size, height: size)
                    .background(Circle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                    .foregroundStyle(Theme.accent)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// Pick a button (or a quick action) to add.
struct ButtonPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var includeSpecials = false
    let exclude: [String]
    let pick: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                List {
                    if includeSpecials {
                        Section("App actions") {
                            ForEach(QuickItem.specials.filter { !exclude.contains($0) }, id: \.self) { id in
                                row(id, QuickItem.label(id), QuickItem.symbol(id))
                            }
                        }
                    }
                    ForEach(KeyGroup.allCases) { g in
                        let options = Keys.all(remote: store.remote).filter { $0.group == g && !exclude.contains($0.id) }
                        if !options.isEmpty {
                            Section(g.rawValue) {
                                ForEach(options) { d in row(d.id, d.label, d.symbol ?? "circle") }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add a button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ id: String, _ label: String, _ symbol: String) -> some View {
        Button {
            pick(id)
            dismiss()
        } label: {
            Label(label, systemImage: symbol).foregroundStyle(.white)
        }
    }
}
