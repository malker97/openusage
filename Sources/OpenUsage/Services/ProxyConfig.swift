import CFNetwork
import Foundation
import Network

/// Optional proxy routing for provider HTTP requests — the same contract as the original app
/// (docs/proxy.md): `~/.openusage/config.json` containing
/// `{"proxy": {"enabled": true, "url": "socks5://127.0.0.1:10808"}}`.
///
/// Loaded once at startup; restart the app after editing the file. Missing, disabled, invalid, or
/// unreadable config leaves proxying off. Credentials may be embedded in the URL
/// (`http://user:pass@host:port`). Loopback hosts always bypass the proxy.
struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Equatable, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: return 1080
            case .http: return 80
            case .https: return 443
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    static let configPath = "~/.openusage/config.json"

    /// The app-wide proxy, read from disk exactly once (first use).
    static let current: ProxyConfig? = load(
        text: try? String(
            contentsOfFile: NSString(string: configPath).expandingTildeInPath,
            encoding: .utf8
        )
    )

    /// Parses config-file text. `nil` unless `proxy.enabled == true` with a valid socks5/http/https
    /// URL — the silent-disable behavior the original documents.
    static func load(text: String?) -> ProxyConfig? {
        guard let text,
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let proxy = root["proxy"] as? [String: Any],
              proxy["enabled"] as? Bool == true,
              let urlString = proxy["url"] as? String,
              let url = URLComponents(string: urlString),
              let schemeRaw = url.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeRaw),
              let host = url.host, !host.isEmpty
        else { return nil }

        return ProxyConfig(
            scheme: scheme,
            host: host,
            port: url.port.flatMap { UInt16(exactly: $0) } ?? scheme.defaultPort,
            username: url.user,
            password: url.password
        )
    }

    /// The Network-framework proxy this config describes, with loopback always excluded.
    @available(macOS 14, *)
    func proxyConfiguration() -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
        var configuration: ProxyConfiguration
        switch scheme {
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        configuration.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        return configuration
    }

    /// CFNetwork's older proxy API routes HTTP and HTTPS destinations through an HTTP CONNECT
    /// proxy, or through SOCKS5. HTTPS *to the proxy itself* needs the newer TLS proxy API.
    func legacyProxyDictionary() throws -> [AnyHashable: Any] {
        var dictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesExceptionsList as String: ["localhost", "127.0.0.1", "::1"]
        ]
        switch scheme {
        case .socks5:
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = Int(port)
            if let username, let password {
                dictionary[kCFStreamPropertySOCKSUser as String] = username
                dictionary[kCFStreamPropertySOCKSPassword as String] = password
            }
        case .http:
            dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPPort as String] = Int(port)
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = Int(port)
        case .https:
            throw ProxyConfigurationError.tlsProxyRequiresSonoma
        }
        return dictionary
    }
}

enum ProxyConfigurationError: Error, LocalizedError {
    case tlsProxyRequiresSonoma

    var errorDescription: String? {
        "TLS connections to an HTTPS proxy require macOS 14. Use an http:// or socks5:// proxy on this Mac."
    }
}
