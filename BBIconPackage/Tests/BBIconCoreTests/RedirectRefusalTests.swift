import Foundation
import Testing
@testable import BBIconCore

/// bb's API never redirects, and a followed redirect carries the request's
/// headers — `x-bb-connect-machine` among them — to whatever host the
/// `Location` names. Both production sessions refuse every redirect, so a 3xx
/// comes back as the answer and is classified like any other refusal.
struct RedirectRefusalTests {
    @Test("the HTTP client hands a 307 back instead of following it to its Location")
    func httpClientDoesNotFollowRedirects() async throws {
        let configuration = URLSessionHTTPClient.defaultConfiguration()
        configuration.protocolClasses = [RedirectingStubProtocol.self]
        let client = URLSessionHTTPClient(configuration: configuration)
        var request = URLRequest(url: try #require(URL(string: "https://\(RedirectingStubProtocol.relayHost)/api/v1/projects")))
        request.setValue("cred-test", forHTTPHeaderField: "x-bb-connect-machine")

        let (_, response) = try await client.send(request)

        #expect(response.statusCode == 307)
        #expect(RedirectingStubProtocol.requestedHosts == [RedirectingStubProtocol.relayHost])
    }

    @Test("the WebSocket upgrade refuses a redirect")
    func webSocketDelegateRefusesRedirects() async throws {
        let from = try #require(URL(string: "https://relay.test/ws"))
        let to = try #require(URL(string: "https://elsewhere.test/ws"))
        let response = try #require(HTTPURLResponse(
            url: from, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // The delegate never looks at the task, so any unstarted one will do.
        let task = session.dataTask(with: from)
        let delegate = URLSessionWebSocketTransport.Delegate(onOpen: {}, onClose: { _, _ in })
        let followed = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: to)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
    }
}

/// Answers every request to `relayHost` with a 307 to `elsewhere.test`, the
/// way `URLSession`'s own HTTP loader reports a redirect: first offered to
/// the delegate, then delivered as the response if the delegate declines.
/// Any other host answers 200, so a followed redirect shows up both in
/// `requestedHosts` and in the status.
final class RedirectingStubProtocol: URLProtocol, @unchecked Sendable {
    static let relayHost = "relay.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static var requestedHosts: [String] { lock.withLock { hosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url, let host = url.host() else { return }
        Self.lock.withLock { Self.hosts.append(host) }
        if host == Self.relayHost, let target = URL(string: "https://elsewhere.test/steal"),
           let response = HTTPURLResponse(
               url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
           ) {
            var redirect = URLRequest(url: target)
            redirect.allHTTPHeaderFields = request.allHTTPHeaderFields
            client.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data())
            client.urlProtocolDidFinishLoading(self)
        } else if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("followed".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
