import Foundation

/// Single URLSession factory + SOCKS5 proxy wiring. After the
/// open-source cut we no longer split traffic between "direct" and
/// "proxied" sources — every request goes through one configurable
/// session. When the user enables a SOCKS5 proxy in Settings, the
/// session is rebuilt with the proxy keys; otherwise it stays
/// direct.
final class ProxyTransport {
    static let shared = ProxyTransport()

    /// The active session — proxied when configured, direct
    /// otherwise. Callers pull this and use it for any outbound
    /// HTTP request.
    private(set) var urlSession: URLSession
    private var currentProxy: ProxyConfig?

    private init() {
        self.urlSession = ProxyTransport.makeDirectSession()
    }

    /// Apply (or clear) the SOCKS5 proxy configuration. Calling
    /// this also invalidates any in-flight tasks on the previous
    /// session.
    func configure(_ proxy: ProxyConfig?) {
        currentProxy = proxy
        urlSession.invalidateAndCancel()
        if let proxy = proxy, proxy.enabled {
            urlSession = ProxyTransport.makeProxiedSession(host: proxy.host, port: proxy.port)
        } else {
            urlSession = ProxyTransport.makeDirectSession()
        }
    }

    // ── Session factories ─────────────────────────────────────────
    private static func makeDirectSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = commonHeaders
        return URLSession(configuration: cfg)
    }

    private static func makeProxiedSession(host: String, port: Int) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = commonHeaders
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port,
            kCFStreamPropertySOCKSProxyHost as String: host,
            kCFStreamPropertySOCKSProxyPort as String: port,
            kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5,
        ]
        return URLSession(configuration: cfg)
    }

    private static let commonHeaders: [AnyHashable: Any] = [
        "User-Agent": "Mozilla/5.0 (compatible; HelixTrading/1.0)",
        "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
    ]
}

/// User-configurable proxy settings. Persisted in UserDefaults
/// (host + port + enabled flag).
struct ProxyConfig: Codable, Equatable {
    var enabled: Bool
    var host: String
    var port: Int

    static let disabled = ProxyConfig(enabled: false, host: "", port: 1080)

    static func load() -> ProxyConfig {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: "proxy.enabled")
        let host = d.string(forKey: "proxy.host") ?? ""
        let port = d.integer(forKey: "proxy.port")
        return ProxyConfig(enabled: enabled, host: host, port: port == 0 ? 1080 : port)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "proxy.enabled")
        d.set(host, forKey: "proxy.host")
        d.set(port, forKey: "proxy.port")
    }
}
