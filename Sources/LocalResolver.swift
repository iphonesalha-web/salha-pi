import Foundation
import Network

/// يحوّل أسماء الشبكة المحلية (مثل pi.local) إلى عنوان IP.
///
/// مكتبة SSH تستعمل getaddrinfo الذي لا يحلّ أسماء ‎.local‎ دائماً على الآيفون.
/// إطار Network من Apple يحلّها عبر Bonjour، ويُظهر طلب إذن «الشبكة المحلية».
enum LocalResolver {
    static func resolve(_ host: String, port: Int, timeout: TimeInterval = 6) async -> String? {
        guard host.lowercased().hasSuffix(".local"),
              let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let params = NWParameters.tcp
            params.preferNoProxies = true
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
            var done = false
            let lock = NSLock()
            func finish(_ value: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, _)? = conn.currentPath?.remoteEndpoint {
                        finish(Self.string(h))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func string(_ h: NWEndpoint.Host) -> String? {
        switch h {
        case .ipv4(let a):
            return "\(a)"
        case .ipv6(let a):
            // نحذف معرّف الواجهة (%en0) — مكتبة SSH لا تقبله
            return "\(a)".components(separatedBy: "%").first
        case .name(let n, _):
            return n
        @unknown default:
            return nil
        }
    }
}
