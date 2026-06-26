import Foundation
import OSLog

/// `URLSession` delegate that enforces the redirect policy (spec §9, P0). Default
/// redirect auto-following is disabled in favor of this explicit per-redirect
/// check: every 3xx is inspected with ``RedirectValidator`` before it is followed.
///
/// Stateless — the original request's host comes from `task.originalRequest`, so
/// no per-task bookkeeping is needed and the delegate is safe to share.
final class HardenedSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "Networking")

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host
        let newHost = request.url?.host

        switch RedirectValidator.decide(originalHost: originalHost, newHost: newHost) {
        case .reject:
            // Passing `nil` stops following; the 3xx surfaces as the response and is
            // treated as an error by the provider's non-2xx status check.
            let from = originalHost ?? "?"
            let to = newHost ?? "?"
            log.error(
                "rejected cross/off-allowlist redirect \(from, privacy: .public) → \(to, privacy: .public)")
            completionHandler(nil)
        case .follow:
            completionHandler(request)
        case .followStripped:
            // Same allowlist, different host: never forward the body or credentials.
            var stripped = request
            stripped.httpBody = nil
            stripped.httpBodyStream = nil
            for header in RedirectValidator.sensitiveHeaders {
                stripped.setValue(nil, forHTTPHeaderField: header)
            }
            completionHandler(stripped)
        }
    }
}

extension URLSession {
    /// A session whose redirects are validated by ``HardenedSessionDelegate`` and
    /// that never persists anything to disk (no cache/cookies — spec §9 "nothing is
    /// persisted to disk in v1"). The delegate is retained by the session.
    static func hardened() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(
            configuration: configuration,
            delegate: HardenedSessionDelegate(),
            delegateQueue: nil)
    }
}
