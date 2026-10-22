import Foundation
import UIKit

/// Android icons come in every shape (circles, rounded squares, odd blobs, padded squares). This turns any of them
/// into a full-bleed square so one squircle mask fits all, iOS style.
enum IconShape {
    static let side: CGFloat = 192
    /// Corner radius as a fraction of the side, matching iOS app icons.
    static let corner: CGFloat = 0.225

    static func normalize(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let n = 128
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * n + x) * 4 + 3]) }
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let i = (y * n + x) * 4
            let a = max(CGFloat(px[i + 3]), 1)
            return (CGFloat(px[i]) / a, CGFloat(px[i + 1]) / a, CGFloat(px[i + 2]) / a)
        }

        // Bounding box of what's actually drawn.
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n { for x in 0..<n where alpha(x, y) > 24 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX, maxY > minY else { return image }
        // Square it around its centre.
        let w = maxX - minX + 1, h = maxY - minY + 1, s = max(w, h)
        let bx = minX - (s - w) / 2, by = minY - (s - h) / 2
        var solid = 0
        for y in max(0, by)..<min(n, by + s) { for x in max(0, bx)..<min(n, bx + s) where alpha(x, y) > 200 { solid += 1 } }
        let coverage = Double(solid) / Double(s * s)

        // The colour just inside the shape's edge, sampled on rays from the centre (median per channel).
        let cx = Double(bx) + Double(s) / 2, cy = Double(by) + Double(s) / 2
        var rs: [CGFloat] = [], gs: [CGFloat] = [], bs: [CGFloat] = []
        for k in 0..<48 {
            let a = Double(k) / 48 * 2 * .pi
            var r = Double(s) / 2 * 1.45
            while r > 2 {
                let x = Int(cx + cos(a) * r), y = Int(cy + sin(a) * r)
                if x >= 0, y >= 0, x < n, y < n, alpha(x, y) > 200 {
                    let xi = Int(cx + cos(a) * max(r - 3, 0)), yi = Int(cy + sin(a) * max(r - 3, 0))
                    if xi >= 0, yi >= 0, xi < n, yi < n, alpha(xi, yi) > 200 {
                        let c = rgb(xi, yi)
                        rs.append(c.0); gs.append(c.1); bs.append(c.2)
                    }
                    break
                }
                r -= 1
            }
        }
        func median(_ v: [CGFloat]) -> CGFloat { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        let edge = UIColor(red: median(rs), green: median(gs), blue: median(bs), alpha: 1)

        // Crop rect in the source image's own pixels.
        let scaleX = CGFloat(cg.width) / CGFloat(n), scaleY = CGFloat(cg.height) / CGFloat(n)
        // A bitmap context's first row in memory is the image's top row, so these are already top-down.
        let crop = CGRect(x: CGFloat(bx) * scaleX, y: CGFloat(by) * scaleY, width: CGFloat(s) * scaleX, height: CGFloat(s) * scaleY)

        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            edge.setFill()
            r.fill(CGRect(origin: .zero, size: size))
            // Already square and full: zoom a hair so its own rounded corners fall outside the mask.
            // Circles and shapes: keep them whole on their own edge colour, which fills the corners.
            let zoom: CGFloat = coverage > 0.9 ? 1.06 : (coverage > 0.75 ? 1.02 : 0.98)
            let d = side * zoom
            let target = CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)
            let src = UIImage(cgImage: cg, scale: 1, orientation: .up)
            UIGraphicsGetCurrentContext()?.saveGState()
            let full = CGRect(x: target.minX - crop.minX * d / crop.width, y: target.minY - crop.minY * d / crop.height,
                              width: CGFloat(cg.width) * d / crop.width, height: CGFloat(cg.height) * d / crop.height)
            UIBezierPath(rect: target).addClip()
            src.draw(in: full)
            UIGraphicsGetCurrentContext()?.restoreGState()
        }
    }
}

/// The app's listing on Google Play: official, full-square, high-res icons, and a name to fall back on.
enum PlayStore {
    static func lookup(_ pkg: String) async -> (icon: UIImage?, title: String?) {
        guard let url = URL(string: "https://play.google.com/store/apps/details?id=\(pkg)&hl=en&gl=CA") else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                      forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return (nil, nil)
        }
        let html = String(decoding: data, as: UTF8.self)
        var title: String?
        if let t = first(#"<meta property="og:title" content="([^"]+)""#, in: html) {
            title = t.replacingOccurrences(of: " - Apps on Google Play", with: "")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
        }
        // The icon is the <img> whose alt is "Icon image"; og:image is a wide banner, so it's only a fallback.
        var src: String?
        for tag in all(#"<img[^>]+>"#, in: html) where tag.contains("Icon image") {
            if let s = first(#"src="(https://play-lh\.googleusercontent\.com/[^"]+)""#, in: tag) { src = s; break }
        }
        if src == nil { src = first(#"itemprop="image"[^>]*src="(https://play-lh\.googleusercontent\.com/[^"]+)""#, in: html) }
        guard let s = src else { return (nil, title) }
        let base = s.components(separatedBy: "=").first ?? s
        guard let iconURL = URL(string: base + "=s512"),
              let (img, _) = try? await URLSession.shared.data(from: iconURL), let image = UIImage(data: img) else { return (nil, title) }
        return (image, title)
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func all(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
}

/// Icons for the TV's own app list, squared off and cached.
@MainActor
final class IconCache: ObservableObject {
    static let shared = IconCache()
    @Published private(set) var images: [String: UIImage] = [:]
    private var started: Set<String> = []

    private static func file(_ key: String) -> String {
        "tvicon2-" + String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(120)) + ".png"
    }

    func image(_ key: String, url: URL?) -> UIImage? {
        if let i = images[key] { return i }
        guard !started.contains(key) else { return nil }
        started.insert(key)
        Task { @MainActor in
            if let d = AppGroup.readData(Self.file(key)), let img = UIImage(data: d) {
                images[key] = img
                return
            }
            guard let url, let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { return }
            let n = IconShape.normalize(img)
            if let png = n.pngData() { AppGroup.writeData(png, Self.file(key)) }
            images[key] = n
        }
        return nil
    }
}
