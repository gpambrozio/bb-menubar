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
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
