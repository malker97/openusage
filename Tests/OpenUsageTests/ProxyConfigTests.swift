import CFNetwork
import Foundation
import XCTest
@testable import OpenUsage

/// Covers the `~/.openusage/config.json` proxy contract (ported from the original's docs/proxy.md):
/// enabled + valid URL parses; everything else silently disables.
final class ProxyConfigTests: XCTestCase {
    func testParsesEnabledSocks5Proxy() {
        let config = ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"socks5://127.0.0.1:10808"}}"#)

        XCTAssertEqual(config?.scheme, .socks5)
        XCTAssertEqual(config?.host, "127.0.0.1")
        XCTAssertEqual(config?.port, 10808)
        XCTAssertNil(config?.username)
    }

    func testParsesAuthenticatedHTTPProxy() {
        let config = ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"http://user:pass@proxy.example.com:8080"}}"#)

        XCTAssertEqual(config?.scheme, .http)
        XCTAssertEqual(config?.host, "proxy.example.com")
        XCTAssertEqual(config?.port, 8080)
        XCTAssertEqual(config?.username, "user")
        XCTAssertEqual(config?.password, "pass")
    }

    func testPercentEncodedCredentialsAreDecoded() {
        let config = ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"http://user%40example:pa%3Ass@proxy.example.com"}}"#)
        XCTAssertEqual(config?.username, "user@example")
        XCTAssertEqual(config?.password, "pa:ss")
    }

    func testLegacyHTTPProxyRoutesBothDestinationSchemesAndExcludesLoopback() throws {
        let proxy = ProxyConfig(scheme: .http, host: "proxy.example.com", port: 8080)
        let dictionary = try proxy.legacyProxyDictionary()
        XCTAssertEqual(dictionary["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPProxy"] as? String, proxy.host)
        XCTAssertEqual(dictionary["HTTPPort"] as? Int, 8080)
        XCTAssertEqual(dictionary["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPSProxy"] as? String, proxy.host)
        XCTAssertEqual(dictionary["HTTPSPort"] as? Int, 8080)
        XCTAssertEqual(dictionary["ExceptionsList"] as? [String], ["localhost", "127.0.0.1", "::1"])
    }

    func testLegacySOCKSProxyKeepsAuthentication() throws {
        let proxy = ProxyConfig(scheme: .socks5, host: "proxy.example.com", port: 1080, username: "user", password: "pass")
        let dictionary = try proxy.legacyProxyDictionary()
        XCTAssertEqual(dictionary["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary[kCFStreamPropertySOCKSUser as String] as? String, "user")
        XCTAssertEqual(dictionary[kCFStreamPropertySOCKSPassword as String] as? String, "pass")
    }

    func testLegacyTLSProxyDoesNotFallBackToDirectConnections() {
        let proxy = ProxyConfig(scheme: .https, host: "proxy.example.com", port: 443)
        XCTAssertThrowsError(try proxy.legacyProxyDictionary())
    }

    func testLegacyCredentialsCannotLeakToOriginOrAnotherProxy() {
        let proxy = ProxyConfig(scheme: .http, host: "proxy.example.com", port: 8080, username: "user", password: "pass")
        let delegate = LegacyProxyCredentialDelegate(proxy: proxy)
        let space = URLProtectionSpace(proxyHost: proxy.host, port: 8080, type: NSURLProtectionSpaceHTTPProxy,
                                       realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertEqual(delegate.credential(for: space, previousFailures: 0)?.user, "user")
        XCTAssertNil(delegate.credential(for: space, previousFailures: 1))
        let origin = URLProtectionSpace(host: proxy.host, port: 8080, protocol: "http",
                                       realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertNil(delegate.credential(for: origin, previousFailures: 0))
        let other = URLProtectionSpace(proxyHost: "other.example.com", port: 8080, type: NSURLProtectionSpaceHTTPProxy,
                                       realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertNil(delegate.credential(for: other, previousFailures: 0))
    }

    func testMissingPortFallsBackToSchemeDefault() {
        XCTAssertEqual(ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"socks5://host"}}"#)?.port, 1080)
        XCTAssertEqual(ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"https://host"}}"#)?.port, 443)
    }

    func testDisabledMissingOrInvalidConfigTurnsProxyOff() {
        XCTAssertNil(ProxyConfig.load(text: #"{"proxy":{"enabled":false,"url":"socks5://127.0.0.1:1080"}}"#))
        XCTAssertNil(ProxyConfig.load(text: #"{"proxy":{"enabled":true,"url":"ftp://127.0.0.1:21"}}"#)) // unsupported scheme
        XCTAssertNil(ProxyConfig.load(text: #"{"proxy":{"enabled":true}}"#))                            // no url
        XCTAssertNil(ProxyConfig.load(text: "not json"))
        XCTAssertNil(ProxyConfig.load(text: nil))                                                       // no config file
        XCTAssertNil(ProxyConfig.load(text: "{}"))
    }
}
