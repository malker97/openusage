import Foundation

/// Credentials are sent only in response to the configured proxy's authentication challenge,
/// never to a provider's endpoint. Immutable state; URLSession owns this delegate for its lifetime.
final class LegacyProxyCredentialDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let proxy: ProxyConfig

    init(proxy: ProxyConfig) { self.proxy = proxy }

    func credential(for space: URLProtectionSpace, previousFailures: Int) -> URLCredential? {
        guard space.isProxy, previousFailures == 0,
              space.authenticationMethod != NSURLAuthenticationMethodServerTrust,
              space.authenticationMethod != NSURLAuthenticationMethodClientCertificate,
              space.host.caseInsensitiveCompare(proxy.host) == .orderedSame,
              space.port == Int(proxy.port),
              let username = proxy.username, let password = proxy.password
        else { return nil }
        return URLCredential(user: username, password: password, persistence: .forSession)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = credential(for: challenge.protectionSpace, previousFailures: challenge.previousFailureCount) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
