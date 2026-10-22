import Foundation
import Compression
import UIKit

/// Reads an app's real name and icon from its APK on the TV, over ADB, without copying the whole APK:
/// it pulls the zip directory, then only AndroidManifest.xml, resources.arsc and the icon image.
enum APKInfo {
    struct Result { var label: String?; var icon: Data? }

    static func read(_ adb: ADB, package pkg: String) async throws -> Result {
        let out = try await adb.shell("pm path \(pkg)")
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("package:") }
        guard let line = lines.first(where: { $0.hasSuffix("/base.apk") }) ?? lines.first else { return Result() }
        let path = String(line.dropFirst(8))
        let zip = try await RemoteZip.open(adb, path)
        guard let manifest = try await zip.read("AndroidManifest.xml") else { return Result() }
        let table = try await zip.read("resources.arsc").flatMap { ResTable($0) }
        let doc = AXML(manifest)
        guard let app = doc.elements.first(where: { $0.name == "application" }) else { return Result() }

        var result = Result()
        if let a = app.attr(name: "label", id: 0x0101_0001) {
            if a.type == 0x03, let s = a.raw ?? doc.string(Int(a.data)) { result.label = s }
            else if a.type == 0x01 { result.label = table?.string(a.data) }
        }
        if let a = app.attr(name: "icon", id: 0x0101_0002) ?? app.attr(name: "roundIcon", id: 0x0101_052c), a.type == 0x01, let table {
            result.icon = try await icon(a.data, table: table, zip: zip)
        }
        if let l = result.label?.trimmingCharacters(in: .whitespacesAndNewlines), l.isEmpty { result.label = nil }
        return result
    }

    /// The app's icon as an image: an adaptive icon's layers put together full-bleed (vectors included),
    /// otherwise the sharpest bitmap, otherwise a rendered vector.
    private static func icon(_ id: UInt32, table: ResTable, zip: RemoteZip) async throws -> Data? {
        let loader = DrawableLoader(table: table, zip: zip)
        let size = CGSize(width: 256, height: 256)
        let files = table.files(id)
        if let xmlPath = files.first(where: { $0.path.hasSuffix(".xml") })?.path,
           let xml = try await zip.read(xmlPath), let root = AXML(xml).root, root.name == "adaptive-icon" {
            let bg = try await loader.layer(root, "background")
            let fg = try await loader.layer(root, "foreground")
            if bg != nil || fg != nil {
                let img = UIGraphicsImageRenderer(size: size).image { ctx in
                    UIColor.black.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    // Adaptive layers are 108dp with the middle 72dp visible.
                    let full = CGRect(x: -size.width * 0.25, y: -size.height * 0.25, width: size.width * 1.5, height: size.height * 1.5)
                    if let bg { DrawableRenderer.draw(bg, in: full, ctx.cgContext) }
                    if let fg { DrawableRenderer.draw(fg, in: full, ctx.cgContext) }
                }
                return img.pngData()
            }
        }
        if let path = table.bestBitmap(id), let bytes = try await zip.read(path), let img = UIImage(data: Data(bytes)) {
            return img.pngData()
        }
        if let d = try await loader.load(id) {
            let img = UIGraphicsImageRenderer(size: size).image { ctx in
                DrawableRenderer.draw(d, in: CGRect(origin: .zero, size: size), ctx.cgContext)
            }
            return img.pngData()
        }
        return nil
    }

    private static func color(_ argb: UInt32) -> UIColor {
        UIColor(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }
}

// MARK: - Byte reading (bounds-checked: a weird APK must never crash the app)

struct Bytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }
    var count: Int { b.count }
    func u8(_ i: Int) -> Int { i >= 0 && i < b.count ? Int(b[i]) : 0 }
    func u16(_ i: Int) -> Int { u8(i) | u8(i + 1) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func i32(_ i: Int) -> Int { Int(u32(i)) }
    func slice(_ i: Int, _ n: Int) -> [UInt8] {
        guard i >= 0, n > 0, i < b.count else { return [] }
        return Array(b[i..<min(b.count, i + n)])
    }

    /// An Android string pool (used by both binary XML and resources.arsc).
    func stringPool(at at: Int) -> [String] {
        let hsize = u16(at + 2)
        let count = min(i32(at + 8), 200_000)
        let utf8 = u32(at + 16) & 0x100 != 0
        let start = at + i32(at + 20)
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var p = start + i32(at + hsize + i * 4)
            if utf8 {
                if u8(p) & 0x80 != 0 { p += 2 } else { p += 1 }
                var n = u8(p); p += 1
                if n & 0x80 != 0 { n = (n & 0x7f) << 8 | u8(p); p += 1 }
                out.append(String(decoding: slice(p, n), as: UTF8.self))
            } else {
                var n = u16(p); p += 2
                if n & 0x8000 != 0 { n = (n & 0x7fff) << 16 | u16(p); p += 2 }
                let units = (0..<min(n, 10_000)).map { UInt16(u16(p + $0 * 2)) }
                out.append(String(decoding: units, as: UTF16.self))
            }
        }
        return out
    }
}

// MARK: - Zip on the TV, read in pieces

struct RemoteZip {
    struct Entry { let method: Int; let compSize: Int; let size: Int; let offset: Int; let nameLen: Int }
    let adb: ADB
    let path: String
    let entries: [String: Entry]

    static func bytes(_ adb: ADB, _ path: String, from offset: Int, count: Int) async throws -> [UInt8] {
        let out = try await adb.shell("tail -c +\(offset + 1) '\(path)' | head -c \(count) | base64", timeout: 60)
        guard let d = Data(base64Encoded: out, options: .ignoreUnknownCharacters) else { throw ADBError("Couldn't read the app's files.") }
        return [UInt8](d)
    }

    static func open(_ adb: ADB, _ path: String) async throws -> RemoteZip {
        guard let size = Int(try await adb.shell("stat -c %s '\(path)'").trimmingCharacters(in: .whitespacesAndNewlines)), size > 22 else {
            throw ADBError("Couldn't read the app's files.")
        }
        let tailLen = min(size, 66_000)
        let tailStart = size - tailLen
        let tail = Bytes(try await bytes(adb, path, from: tailStart, count: tailLen))
        var e = tail.count - 22
        while e >= 0, tail.u32(e) != 0x0605_4b50 { e -= 1 }
        guard e >= 0 else { throw ADBError("That app's APK isn't a normal zip.") }
        let cdSize = tail.i32(e + 12), cdOff = tail.i32(e + 16)
        let cd: Bytes
        if cdOff >= tailStart {
            cd = Bytes(tail.slice(cdOff - tailStart, cdSize))
        } else {
            cd = Bytes(try await bytes(adb, path, from: cdOff, count: cdSize))
        }
        var entries: [String: Entry] = [:]
        var p = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x0201_4b50 {
            let n = cd.u16(p + 28), x = cd.u16(p + 30), c = cd.u16(p + 32)
            let name = String(decoding: cd.slice(p + 46, n), as: UTF8.self)
            entries[name] = Entry(method: cd.u16(p + 10), compSize: cd.i32(p + 20), size: cd.i32(p + 24), offset: cd.i32(p + 42), nameLen: n)
            p += 46 + n + x + c
        }
        return RemoteZip(adb: adb, path: path, entries: entries)
    }

    func read(_ name: String) async throws -> [UInt8]? {
        guard let e = entries[name], e.compSize < 24_000_000 else { return nil }
        var raw = Bytes(try await Self.bytes(adb, path, from: e.offset, count: 30 + e.nameLen + 512 + e.compSize))
        guard raw.u32(0) == 0x0403_4b50 else { return nil }
        let start = 30 + raw.u16(26) + raw.u16(28)
        if start + e.compSize > raw.count {
            raw = Bytes(try await Self.bytes(adb, path, from: e.offset, count: start + e.compSize))
        }
        let data = raw.slice(start, e.compSize)
        switch e.method {
        case 0: return data
        case 8: return Self.inflate(data, e.size)
        default: return nil
        }
    }

    static func inflate(_ src: [UInt8], _ size: Int) -> [UInt8]? {
        guard !src.isEmpty, size > 0, size < 64_000_000 else { return nil }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Array(dst.prefix(n)) : nil
    }
}

// MARK: - Binary XML (AndroidManifest.xml, adaptive icons)

struct AXML {
    struct Attr { let name: String; let resID: UInt32?; let raw: String?; let type: Int; let data: UInt32 }
    struct Element {
        let name: String
        let attrs: [Attr]
        func attr(name n: String, id: UInt32) -> Attr? {
            attrs.first { $0.resID == id } ?? attrs.first { $0.name == n }
        }
    }

    /// The same elements as a tree (vector drawables need nesting for groups).
    final class Node {
        let name: String
        let attrs: [Attr]
        var children: [Node] = []
        init(name: String, attrs: [Attr]) { self.name = name; self.attrs = attrs }
        func attr(_ n: String, id: UInt32? = nil) -> Attr? {
            if let id, let a = attrs.first(where: { $0.resID == id }) { return a }
            return attrs.first { $0.name == n }
        }
    }

    private(set) var strings: [String] = []
    private(set) var elements: [Element] = []
    private(set) var root: Node?

    func string(_ i: Int) -> String? { i >= 0 && i < strings.count ? strings[i] : nil }

    init(_ bytes: [UInt8]) {
        let b = Bytes(bytes)
        guard b.u16(0) == 0x0003 else { return }
        var resMap: [UInt32] = []
        var stack: [Node] = []
        var pos = b.u16(2)
        var guardCount = 0
        while pos + 8 <= b.count, guardCount < 200_000 {
            guardCount += 1
            let type = b.u16(pos), hsize = b.u16(pos + 2), csize = b.i32(pos + 4)
            guard csize >= 8 else { break }
            switch type {
            case 0x0001:
                strings = b.stringPool(at: pos)
            case 0x0180:
                resMap = stride(from: pos + hsize, to: pos + csize, by: 4).map { b.u32($0) }
            case 0x0102:
                let ext = pos + hsize
                let nameIdx = b.i32(ext + 4)
                let attrStart = b.u16(ext + 8), attrSize = max(b.u16(ext + 10), 20), count = b.u16(ext + 12)
                var attrs: [Attr] = []
                for i in 0..<count {
                    let a = ext + attrStart + i * attrSize
                    let n = b.i32(a + 4)
                    let rawIdx = b.u32(a + 8)
                    attrs.append(Attr(name: string(n) ?? "", resID: n < resMap.count ? resMap[n] : nil,
                                      raw: rawIdx == 0xffff_ffff ? nil : string(Int(rawIdx)),
                                      type: b.u8(a + 15), data: b.u32(a + 16)))
                }
                elements.append(Element(name: string(nameIdx) ?? "", attrs: attrs))
                let node = Node(name: string(nameIdx) ?? "", attrs: attrs)
                if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
                stack.append(node)
            case 0x0103:
                if !stack.isEmpty { stack.removeLast() }
            default:
                break
            }
            pos += csize
        }
    }
}

// MARK: - resources.arsc

struct ResTable {
    struct Value { let density: Int; let lang: String; let type: Int; let data: UInt32 }
    private var strings: [String] = []
    private var values: [UInt32: [Value]] = [:]

    init?(_ bytes: [UInt8]) {
        let b = Bytes(bytes)
        guard b.u16(0) == 0x0002 else { return nil }
        var pos = b.u16(2)
        while pos + 8 <= b.count {
            let type = b.u16(pos), csize = b.i32(pos + 4)
            guard csize >= 8 else { break }
            if type == 0x0001 { strings = b.stringPool(at: pos) }
            if type == 0x0200 { readPackage(b, pos, csize) }
            pos += csize
        }
    }

    private mutating func readPackage(_ b: Bytes, _ at: Int, _ size: Int) {
        let pid = b.u32(at + 8) & 0xff
        var p = at + b.u16(at + 2)
        while p + 8 <= at + size {
            let type = b.u16(p), hsize = b.u16(p + 2), csize = b.i32(p + 4)
            guard csize >= 8 else { break }
            if type == 0x0201 {
                let tid = UInt32(b.u8(p + 8)), flags = b.u8(p + 9)
                let count = min(b.i32(p + 12), 100_000), entriesStart = b.i32(p + 16)
                let config = p + 20
                let density = b.u16(config + 14)
                let lang = String(decoding: b.slice(config + 8, 2).filter { $0 != 0 }, as: UTF8.self)
                let offsets = p + hsize
                var collected: [(UInt32, Value)] = []
                func entry(_ idx: Int, _ off: Int) {
                    let e = p + entriesStart + off
                    let eflags = b.u16(e + 2)
                    let value: Value
                    if eflags & 0x0008 != 0 {            // compact entry
                        value = Value(density: density, lang: lang, type: (eflags >> 8) & 0xff, data: b.u32(e + 4))
                    } else {
                        guard eflags & 0x0001 == 0 else { return }   // complex (styles, arrays): not needed
                        let v = e + b.u16(e)
                        value = Value(density: density, lang: lang, type: b.u8(v + 3), data: b.u32(v + 4))
                    }
                    let id = pid << 24 | tid << 16 | UInt32(idx & 0xffff)
                    collected.append((id, value))
                }
                if flags & 0x01 != 0 {                   // sparse
                    for i in 0..<count { entry(b.u16(offsets + i * 4), b.u16(offsets + i * 4 + 2) * 4) }
                } else if flags & 0x02 != 0 {            // 16-bit offsets
                    for i in 0..<count { let o = b.u16(offsets + i * 2); if o != 0xffff { entry(i, o * 4) } }
                } else {
                    for i in 0..<count { let o = b.u32(offsets + i * 4); if o != 0xffff_ffff { entry(i, Int(o)) } }
                }
                for (k, v) in collected { values[k, default: []].append(v) }
            }
            p += csize
        }
    }

    /// Every value for an id, following references a few levels deep.
    func resolve(_ id: UInt32, depth: Int = 0) -> [Value] {
        guard depth < 5, let list = values[id] else { return [] }
        return list.flatMap { v in v.type == 0x01 && v.data != id ? resolve(v.data, depth: depth + 1) : [v] }
    }

    func string(_ id: UInt32) -> String? {
        let list = resolve(id).filter { $0.type == 0x03 }
        let pick = list.first { $0.lang.isEmpty } ?? list.first { $0.lang == "en" } ?? list.first
        guard let pick, Int(pick.data) < strings.count else { return nil }
        return strings[Int(pick.data)]
    }

    func color(_ id: UInt32) -> UInt32? {
        resolve(id).first { (0x1c...0x1f).contains($0.type) }?.data
    }

    func files(_ id: UInt32) -> [(density: Int, path: String)] {
        resolve(id).compactMap { v in
            guard v.type == 0x03, Int(v.data) < strings.count else { return nil }
            return (v.density, strings[Int(v.data)])
        }
    }

    /// The highest-density PNG/WebP/JPEG for a drawable id.
    func bestBitmap(_ id: UInt32) -> String? {
        let bitmaps = files(id).filter { f in [".png", ".webp", ".jpg"].contains { f.path.lowercased().hasSuffix($0) } }
        func rank(_ d: Int) -> Int { d == 0 ? 160 : (d >= 0xfffe ? 0 : d) }
        return bitmaps.max { rank($0.density) < rank($1.density) }?.path
    }
}
