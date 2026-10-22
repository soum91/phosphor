import Foundation
import Network

/// A TV seen on the network.
struct FoundTV: Identifiable, Equatable {
    var id: String { host }
    var name: String
    var host: String
    var model: String?
    /// True once it answered Sony's IP control.
    var isBravia = false
}

/// Finds the TV by its Google Cast and Android TV Bonjour services, then checks which ones speak Sony IP control.
@MainActor
final class TVFinder: ObservableObject {
    @Published var found: [FoundTV] = []
    @Published var searching = false
    private var browsers: [NWBrowser] = []
    private var seen: Set<String> = []

    func start() {
        stop()
        searching = true
        found = []
        seen = []
        for type in ["_googlecast._tcp", "_androidtvremote2._tcp"] {
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                for r in results {
                    guard case .service(let name, _, _, _) = r.endpoint else { continue }
                    var friendly = name, model: String?
                    if case .bonjour(let txt) = r.metadata {
                        if let fn = txt["fn"], !fn.isEmpty { friendly = fn }
                        if let md = txt["md"], !md.isEmpty { model = md }
                    }
                    let f = friendly, m = model
                    Task { @MainActor in await self?.resolve(r.endpoint, name: f, model: m) }
                }
            }
            b.start(queue: .main)
            browsers.append(b)
        }
        Task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if searching { searching = false }
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        searching = false
    }

    private func resolve(_ endpoint: NWEndpoint, name: String, model: String?) async {
        guard let host = await Self.address(of: endpoint), !seen.contains(host) else { return }
        seen.insert(host)
        var tv = FoundTV(name: Self.clean(name), host: host, model: model)
        found.append(tv)
        if let info = try? await Bravia(host: host, psk: "", timeout: 3).interfaceInfo() {
            tv.isBravia = true
            if let m = info.model, !m.isEmpty { tv.model = m }
        }
        if let i = found.firstIndex(where: { $0.host == host }) { found[i] = tv }
        // Sony ones first.
        found.sort { ($0.isBravia ? 0 : 1, $0.name) < ($1.isBravia ? 0 : 1, $1.name) }
    }

    /// Cast service names look like "BRAVIA-4K-…-1a2b3c…": keep the readable part.
    private static func clean(_ n: String) -> String {
        var s = n
        if let r = s.range(of: "-[0-9a-f]{24,}$", options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    /// Opens a throwaway connection to learn the service's IPv4 address.
    static func address(of endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, _)? = c.currentPath?.remoteEndpoint, once.fire() {
                        var host = "\(h)"
                        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                        cont.resume(returning: host)
                    } else if once.fire() { cont.resume(returning: nil) }
                    c.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if once.fire() { cont.resume(returning: nil); c.cancel() }
            }
        }
    }
}
