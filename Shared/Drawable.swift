import Foundation
import UIKit

/// Android drawables, enough of them to draw app icons: bitmaps, colors, vector drawables (paths, groups,
/// gradients), insets, layer lists and simple shapes.
indirect enum Drawable {
    case bitmap(UIImage)
    case color(UIColor)
    case vector(VectorGroup, viewport: CGSize)
    case inset(Drawable, left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)
    case layers([Drawable])
}

enum Paint {
    case solid(UIColor)
    case linear(colors: [UIColor], locations: [CGFloat], start: CGPoint, end: CGPoint)
    case radial(colors: [UIColor], locations: [CGFloat], center: CGPoint, radius: CGFloat)
}

struct VectorPath {
    var path: CGPath
    var fill: Paint?
    var fillAlpha: CGFloat = 1
    var stroke: Paint?
    var strokeWidth: CGFloat = 0
    var strokeAlpha: CGFloat = 1
    var evenOdd = false
}

final class VectorGroup {
    var transform: CGAffineTransform = .identity
    var items: [VectorItem] = []
}

enum VectorItem {
    case path(VectorPath)
    case group(VectorGroup)
    case clip(CGPath)
}

// MARK: - Loading from the APK

struct DrawableLoader {
    let table: ResTable
    let zip: RemoteZip

    /// The <background>/<foreground> layer of an adaptive icon.
    func layer(_ root: AXML.Node, _ tag: String) async throws -> Drawable? {
        guard let el = root.children.first(where: { $0.name == tag }) else { return nil }
        if let a = el.attr("drawable", id: 0x0101_0199) { return try await value(a, depth: 0) }
        if let child = el.children.first { return try await node(child, depth: 0) }
        return nil
    }

    /// A drawable resource by id: a color, the sharpest bitmap, or an XML drawable.
    func load(_ id: UInt32, depth: Int = 0) async throws -> Drawable? {
        guard depth < 6 else { return nil }
        if let c = table.color(id) { return .color(Self.color(c)) }
        if let p = table.bestBitmap(id), let b = try await zip.read(p), let img = UIImage(data: Data(b)) { return .bitmap(img) }
        guard let xmlPath = table.files(id).first(where: { $0.path.hasSuffix(".xml") })?.path,
              let xml = try await zip.read(xmlPath), let root = AXML(xml).root else { return nil }
        return try await node(root, depth: depth + 1)
    }

    private func value(_ a: AXML.Attr, depth: Int) async throws -> Drawable? {
        if (0x1c...0x1f).contains(a.type) { return .color(Self.color(a.data)) }
        if a.type == 0x01 { return try await load(a.data, depth: depth + 1) }
        return nil
    }

    private func node(_ n: AXML.Node, depth: Int) async throws -> Drawable? {
        switch n.name {
        case "vector":
            let vw = num(n.attr("viewportWidth", id: 0x0101_0402)) ?? 24
            let vh = num(n.attr("viewportHeight", id: 0x0101_0403)) ?? 24
            let g = VectorGroup()
            try await fill(g, n.children, depth: depth)
            return .vector(g, viewport: CGSize(width: vw, height: vh))
        case "bitmap", "nine-patch":
            if let a = n.attr("src", id: 0x0101_0119) { return try await value(a, depth: depth) }
        case "inset":
            var inner: Drawable?
            if let a = n.attr("drawable", id: 0x0101_0199) { inner = try await value(a, depth: depth) }
            if inner == nil, let c = n.children.first { inner = try await node(c, depth: depth + 1) }
            guard let inner else { return nil }
            let all = frac(n.attr("inset"))
            return .inset(inner, left: frac(n.attr("insetLeft")) ?? all ?? 0, top: frac(n.attr("insetTop")) ?? all ?? 0,
                          right: frac(n.attr("insetRight")) ?? all ?? 0, bottom: frac(n.attr("insetBottom")) ?? all ?? 0)
        case "layer-list":
            var out: [Drawable] = []
            for item in n.children where item.name == "item" {
                var d: Drawable?
                if let a = item.attr("drawable", id: 0x0101_0199) { d = try await value(a, depth: depth) }
                if d == nil, let c = item.children.first { d = try await node(c, depth: depth + 1) }
                if let d { out.append(d) }
            }
            return out.isEmpty ? nil : .layers(out)
        case "shape":
            if let solid = n.children.first(where: { $0.name == "solid" }), let a = solid.attr("color", id: 0x0101_01a5),
               let c = try await color(a) {
                return .color(c)
            }
            if let g = n.children.first(where: { $0.name == "gradient" }), let a = g.attr("startColor", id: 0x0101_019d),
               let c = try await color(a) {
                return .color(c)
            }
        case "color", "selector":
            if let item = n.children.first(where: { $0.name == "item" }), let a = item.attr("color", id: 0x0101_01a5) {
                return try await color(a).map { .color($0) }
            }
        default:
            break
        }
        return nil
    }

    private func fill(_ g: VectorGroup, _ nodes: [AXML.Node], depth: Int) async throws {
        for n in nodes {
            switch n.name {
            case "path":
                guard let d = string(n.attr("pathData", id: 0x0101_0405)), let path = SVGPath.parse(d) else { continue }
                var p = VectorPath(path: path)
                if let a = n.attr("fillColor", id: 0x0101_0404) { p.fill = try await paint(a) }
                if let a = n.attr("strokeColor", id: 0x0101_0406) { p.stroke = try await paint(a) }
                p.strokeWidth = CGFloat(num(n.attr("strokeWidth", id: 0x0101_0407)) ?? 0)
                p.fillAlpha = CGFloat(num(n.attr("fillAlpha", id: 0x0101_04cc)) ?? 1)
                p.strokeAlpha = CGFloat(num(n.attr("strokeAlpha", id: 0x0101_04cb)) ?? 1)
                p.evenOdd = (num(n.attr("fillType", id: 0x0101_051e)) ?? 0) == 1
                g.items.append(.path(p))
            case "group":
                let sub = VectorGroup()
                let px = num(n.attr("pivotX")) ?? 0, py = num(n.attr("pivotY")) ?? 0
                let tx = num(n.attr("translateX")) ?? 0, ty = num(n.attr("translateY")) ?? 0
                let sx = num(n.attr("scaleX")) ?? 1, sy = num(n.attr("scaleY")) ?? 1
                let rot = (num(n.attr("rotation")) ?? 0) * .pi / 180
                // Android: translate(tx + px, ty + py) · rotate · scale · translate(-px, -py)
                var t = CGAffineTransform(translationX: tx + px, y: ty + py)
                t = t.rotated(by: rot)
                t = t.scaledBy(x: sx, y: sy)
                t = t.translatedBy(x: -px, y: -py)
                sub.transform = t
                try await fill(sub, n.children, depth: depth)
                g.items.append(.group(sub))
            case "clip-path":
                if let d = string(n.attr("pathData", id: 0x0101_0405)), let path = SVGPath.parse(d) { g.items.append(.clip(path)) }
            default:
                break
            }
        }
    }

    // MARK: Values

    private func string(_ a: AXML.Attr?) -> String? {
        guard let a else { return nil }
        if let r = a.raw { return r }
        if a.type == 0x01 { return table.string(a.data) }
        return nil
    }

    func num(_ a: AXML.Attr?) -> Double? {
        guard let a else { return nil }
        switch a.type {
        case 0x04: return Double(Float(bitPattern: a.data))
        case 0x10, 0x11: return Double(Int32(bitPattern: a.data))
        case 0x12: return a.data != 0 ? 1 : 0
        case 0x05, 0x06: return Self.complex(a.data)
        case 0x03: return a.raw.flatMap(Double.init)
        default: return nil
        }
    }

    private func frac(_ a: AXML.Attr?) -> CGFloat? {
        guard let a, a.type == 0x06 || a.type == 0x04 else { return nil }
        return num(a).map { CGFloat($0) }
    }

    /// Android's packed dimension/fraction format.
    static func complex(_ data: UInt32) -> Double {
        let mantissa = Double(Int32(bitPattern: data & 0xffff_ff00)) / 256
        let mult = [1.0, 1.0 / 128, 1.0 / 32768, 1.0 / 8_388_608][Int((data >> 4) & 3)]
        return mantissa * mult
    }

    static func color(_ argb: UInt32) -> UIColor {
        UIColor(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }

    private func color(_ a: AXML.Attr) async throws -> UIColor? {
        if case .solid(let c)? = try await paint(a) { return c }
        if case .linear(let cs, _, _, _)? = try await paint(a) { return cs.first }
        if case .radial(let cs, _, _, _)? = try await paint(a) { return cs.first }
        return nil
    }

    /// A fill or stroke: a color, a color resource, a color selector or a gradient file.
    private func paint(_ a: AXML.Attr) async throws -> Paint? {
        if (0x1c...0x1f).contains(a.type) { return .solid(Self.color(a.data)) }
        guard a.type == 0x01 else { return nil }
        if let c = table.color(a.data) { return .solid(Self.color(c)) }
        guard let xmlPath = table.files(a.data).first(where: { $0.path.hasSuffix(".xml") })?.path,
              let xml = try await zip.read(xmlPath), let root = AXML(xml).root else { return nil }
        if root.name == "gradient" {
            var colors: [UIColor] = []
            var locs: [CGFloat] = []
            for item in root.children where item.name == "item" {
                if let ca = item.attr("color", id: 0x0101_01a5), (0x1c...0x1f).contains(ca.type) {
                    colors.append(Self.color(ca.data))
                    locs.append(CGFloat(num(item.attr("offset")) ?? Double(locs.count)))
                }
            }
            if colors.isEmpty {
                for (k, loc) in [("startColor", 0.0), ("centerColor", 0.5), ("endColor", 1.0)] {
                    if let ca = root.attr(k), (0x1c...0x1f).contains(ca.type) { colors.append(Self.color(ca.data)); locs.append(loc) }
                }
            }
            guard !colors.isEmpty else { return nil }
            if colors.count == 1 { return .solid(colors[0]) }
            let type = num(root.attr("type")) ?? 0
            if type == 1 {
                return .radial(colors: colors, locations: locs,
                               center: CGPoint(x: num(root.attr("centerX")) ?? 0, y: num(root.attr("centerY")) ?? 0),
                               radius: CGFloat(num(root.attr("gradientRadius")) ?? 1))
            }
            return .linear(colors: colors, locations: locs,
                           start: CGPoint(x: num(root.attr("startX")) ?? 0, y: num(root.attr("startY")) ?? 0),
                           end: CGPoint(x: num(root.attr("endX")) ?? 0, y: num(root.attr("endY")) ?? 0))
        }
        if let item = root.children.first(where: { $0.name == "item" }), let ca = item.attr("color", id: 0x0101_01a5),
           (0x1c...0x1f).contains(ca.type) {
            return .solid(Self.color(ca.data))
        }
        return nil
    }
}

// MARK: - Drawing

enum DrawableRenderer {
    static func draw(_ d: Drawable, in rect: CGRect, _ cg: CGContext) {
        switch d {
        case .bitmap(let img):
            UIGraphicsPushContext(cg)
            img.draw(in: rect)
            UIGraphicsPopContext()
        case .color(let c):
            cg.setFillColor(c.cgColor)
            cg.fill(rect)
        case .inset(let inner, let l, let t, let r, let b):
            let w = rect.width, h = rect.height
            draw(inner, in: CGRect(x: rect.minX + w * l, y: rect.minY + h * t, width: w * (1 - l - r), height: h * (1 - t - b)), cg)
        case .layers(let list):
            for x in list { draw(x, in: rect, cg) }
        case .vector(let g, let vp):
            guard vp.width > 0, vp.height > 0 else { return }
            cg.saveGState()
            cg.translateBy(x: rect.minX, y: rect.minY)
            cg.scaleBy(x: rect.width / vp.width, y: rect.height / vp.height)
            group(g, cg)
            cg.restoreGState()
        }
    }

    private static func group(_ g: VectorGroup, _ cg: CGContext) {
        cg.saveGState()
        cg.concatenate(g.transform)
        for item in g.items {
            switch item {
            case .group(let sub): group(sub, cg)
            case .clip(let p): cg.addPath(p); cg.clip()
            case .path(let p): path(p, cg)
            }
        }
        cg.restoreGState()
    }

    private static func path(_ p: VectorPath, _ cg: CGContext) {
        if let f = p.fill {
            cg.saveGState()
            cg.setAlpha(p.fillAlpha)
            cg.addPath(p.path)
            paint(f, cg, rule: p.evenOdd ? .evenOdd : .winding, bounds: p.path.boundingBoxOfPath)
            cg.restoreGState()
        }
        if let s = p.stroke, p.strokeWidth > 0 {
            cg.saveGState()
            cg.setAlpha(p.strokeAlpha)
            cg.setLineWidth(p.strokeWidth)
            cg.addPath(p.path)
            cg.replacePathWithStrokedPath()
            paint(s, cg, rule: .winding, bounds: p.path.boundingBoxOfPath.insetBy(dx: -p.strokeWidth, dy: -p.strokeWidth))
            cg.restoreGState()
        }
    }

    /// Fills the current path with a color or gradient.
    private static func paint(_ f: Paint, _ cg: CGContext, rule: CGPathFillRule, bounds: CGRect) {
        switch f {
        case .solid(let c):
            cg.setFillColor(c.cgColor)
            cg.fillPath(using: rule)
        case .linear(let cs, let locs, let a, let b):
            cg.clip(using: rule)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cs.map(\.cgColor) as CFArray, locations: locs) {
                cg.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .radial(let cs, let locs, let c, let r):
            cg.clip(using: rule)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cs.map(\.cgColor) as CFArray, locations: locs) {
                cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
            }
        }
    }
}

// MARK: - SVG path data (what android:pathData uses)

enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        let chars = Array(d.utf8)
        var i = 0
        let path = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastCmd: UInt8 = 0
        var cmd: UInt8 = 0

        func skip() { while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 9 || chars[i] == 10 || chars[i] == 13 { i += 1 } }
        func isCmd(_ c: UInt8) -> Bool { (c >= 65 && c <= 90 || c >= 97 && c <= 122) && c != 101 && c != 69 }
        func number() -> CGFloat? {
            skip()
            guard i < chars.count else { return nil }
            let s = i
            if chars[i] == 43 || chars[i] == 45 { i += 1 }
            var dot = false, digits = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { digits = true; i += 1 }
                else if c == 46 && !dot { dot = true; i += 1 }
                else if (c == 101 || c == 69) && digits {
                    i += 1
                    if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
                    while i < chars.count, chars[i] >= 48 && chars[i] <= 57 { i += 1 }
                    break
                } else { break }
            }
            guard digits, let v = Double(String(decoding: chars[s..<i], as: UTF8.self)) else { i = s; return nil }
            return CGFloat(v)
        }
        func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else { return nil }
            defer { i += 1 }
            return chars[i] == 49
        }

        var guardCount = 0
        while i < chars.count, guardCount < 100_000 {
            guardCount += 1
            skip()
            guard i < chars.count else { break }
            if isCmd(chars[i]) { cmd = chars[i]; i += 1 } else if cmd == 0 { return nil }
            let rel = cmd >= 97
            let base = rel ? cur : .zero
            switch cmd | 0x20 {
            case 109: // m
                guard let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.move(to: cur)
                start = cur
                cmd = rel ? 108 : 76 // further pairs are lineto
                lastCtrl = nil
            case 108: // l
                guard let x = number(), let y = number() else { return path }
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: cur)
                lastCtrl = nil
            case 104: // h
                guard let x = number() else { return path }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y)
                path.addLine(to: cur)
                lastCtrl = nil
            case 118: // v
                guard let y = number() else { return path }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y)
                path.addLine(to: cur)
                lastCtrl = nil
            case 99: // c
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1), c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2
            case 115: // s
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let c1 = (lastCmd | 0x20 == 99 || lastCmd | 0x20 == 115) ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2
            case 113: // q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastCtrl = c
            case 116: // t
                guard let x = number(), let y = number() else { return path }
                let c = (lastCmd | 0x20 == 113 || lastCmd | 0x20 == 116) ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastCtrl = c
            case 97: // a
                guard let rx = number(), let ry = number(), let rot = number(), let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return path }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                arc(path, from: cur, to: end, rx: abs(rx), ry: abs(ry), angle: rot, large: large, sweep: sweep)
                cur = end
                lastCtrl = nil
            case 122: // z
                path.closeSubpath()
                cur = start
                lastCtrl = nil
            default:
                return path.isEmpty ? nil : path
            }
            lastCmd = cmd
        }
        return path.isEmpty ? nil : path
    }

    /// SVG elliptical arc → cubic Béziers (endpoint to center parameterization, per the SVG spec).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = rx, ry = ry
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = angle * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { rx *= sqrt(lam); ry *= sqrt(lam) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = c * cx1 - s * cy1 + (p0.x + p1.x) / 2, cy = s * cx1 + c * cy1 + (p0.y + p1.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segs)
        let kappa = 4.0 / 3.0 * tan(step / 4)
        var t = t1
        func pt(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * c - ry * sin(a) * s, y: cy + rx * cos(a) * s + ry * sin(a) * c)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * c - ry * cos(a) * s, y: -rx * sin(a) * s + ry * cos(a) * c)
        }
        for _ in 0..<segs {
            let a0 = t, a1 = t + step
            let q0 = pt(a0), q1 = pt(a1), d0 = deriv(a0), d1 = deriv(a1)
            path.addCurve(to: q1, control1: CGPoint(x: q0.x + kappa * d0.x, y: q0.y + kappa * d0.y),
                          control2: CGPoint(x: q1.x - kappa * d1.x, y: q1.y - kappa * d1.y))
            t = a1
        }
    }
}
