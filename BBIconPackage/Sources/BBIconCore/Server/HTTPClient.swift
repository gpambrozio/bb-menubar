import Foundation

/// One HTTP round trip, injected so `BBAPI` is tested against a table of
/// answers instead of a running bb.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production client. Ephemeral, so nothing about bb is written to disk,
/// and never answered from a cache: every fetch is a re-read after bb said
/// something changed. bb is on loopback, so a request that takes 10 s is a
/// hung server, not a slow network.
///
/// The request timeout only bounds the wait between bytes, so a server that
/// trickles its answer could hold one request open indefinitely. The
/// resource timeout bounds each request as a whole at 30 s.
///
/// Cookies are neither stored nor sent: every request carries exactly the
/// headers its caller set.
///
/// Redirects are never followed. bb's API does not redirect, and a followed
/// redirect carries the request's headers — a remote bb's
/// `x-bb-connect-machine` credential among them — to whatever host the
/// `Location` names. A 3xx is handed back as the answer instead, and each
/// caller classifies it like any other refusal.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        self.init(configuration: Self.defaultConfiguration())
    }

    /// Tests pass `defaultConfiguration()` with a stub `URLProtocol` added.
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // No cookie store. The relay's desktop session is minted over this
        // client and belongs on one `/ws` upgrade only; a `Set-Cookie` that
        // came with it must not be kept and replayed on every later request.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Declines every redirect, so `URLSession` returns the 3xx itself. Stateless,
/// so `Sendable` as checked, not `@unchecked`.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
