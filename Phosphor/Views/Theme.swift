import SwiftUI

enum Theme {
    static let accent = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let deep = Color(red: 0.95, green: 0.22, blue: 0.72)
    static let bgTop = Color(red: 0.02, green: 0.01, blue: 0.04)
    static let bgBottom = Color.black
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let off = Color(white: 0.45)
    static let danger = Color(red: 1, green: 0.45, blue: 0.42)

    static func background(_ glow: Color = accent, strength: Double = 0.22) -> some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [glow.opacity(strength), .clear], center: .top, startRadius: 10, endRadius: 540)
            RadialGradient(colors: [deep.opacity(strength * 0.8), .clear], center: .bottom, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.5))
    }
}

/// Round remote-style button.
struct KeyButton: View {
    let symbol: String?
    let label: String
    var size: CGFloat = 58
    var tint: Color = .white
    var filled = false
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: size * 0.34, weight: .semibold))
                        } else {
                            Text(String(label.prefix(3))).font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                        }
                    }
                    .frame(width: size, height: size)
                    .background(filled ? tint : Color.white.opacity(0.08), in: Circle())
                    .foregroundStyle(filled ? .black : tint)
                    .overlay(Circle().stroke(Theme.stroke))
                    if badge {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9).offset(x: -3, y: 3)
                    }
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Chip: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(selected ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        .foregroundStyle(selected ? .black : .white)
        .overlay(Capsule().stroke(selected ? .clear : Theme.stroke))
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke))
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension Int {
    var asTime: Date {
        Calendar.current.date(bySettingHour: self / 60, minute: self % 60, second: 0, of: .now) ?? .now
    }
}

extension Date {
    var minutesOfDay: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

func timeBinding(_ b: Binding<Int>) -> Binding<Date> {
    Binding(get: { b.wrappedValue.asTime }, set: { b.wrappedValue = $0.minutesOfDay })
}
