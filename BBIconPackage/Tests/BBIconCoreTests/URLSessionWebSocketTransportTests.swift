import Foundation
import Testing
@testable import BBIconCore

/// What the real `URLSessionWebSocketTransport` puts on the wire, against a
/// server on loopback that refuses the upgrade the way the getbb.app relay
/// refuses one it will not accept (HTTP 401, an HTML body). Nothing leaves
/// the Mac.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct URLSessionWebSocketTransportTests {
    static let cookie = "__Secure-bb-connect.desktop_session=session-test"

    /// Dials `server` with `headers`, and returns the text of the first
    /// `onError` once the server has seen the request.
    private func dial(_ server: LoopbackHTTPServer, headers: [String: String]) async throws -> String? {
        let port = try await server.start()
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: url, headers: headers))
        var failure: String?
        transport.onError = { if failure == nil { failure = $0 } }
        transport.connect()
        defer { transport.close(code: 1000, reason: "test") }
        await eventually { failure != nil && !server.requestHeads.isEmpty }
        return failure
    }

    @Test("the upgrade carries the Cookie and machine headers exactly as given, and no Origin")
    func upgradeCarriesHeaders() async throws {
        let server = try LoopbackHTTPServer(status: 401, reason: "Unauthorized", body: "<html>Unauthorized</html>")
        defer { server.stop() }
        _ = try await dial(server, headers: ["Cookie": Self.cookie, "x-bb-connect-machine": "cred-test"])
        let head = try #require(server.requestHeads.first)
        #expect(head.hasPrefix("GET /ws HTTP/1.1"))
        #expect(head.headerValue("Cookie") == Self.cookie)
        #expect(head.headerValue("x-bb-connect-machine") == "cred-test")
        #expect(head.headerValue("Origin") == nil)
    }

    @Test("an upgrade the server refuses is named by its status", arguments: [
        (401, "Unauthorized"),
        (403, "Forbidden"),
        (502, "Bad Gateway"),
    ])
    func refusedUpgradeIsNamed(status: Int, reason: String) async throws {
        let server = try LoopbackHTTPServer(status: status, reason: reason, body: "<html>\(reason)</html>")
        defer { server.stop() }
        let failure = try await dial(server, headers: [:])
        #expect(failure == "the server refused the connection (HTTP \(status))")
    }

    enum Event: Equatable {
        case error(String)
        case close(Int)
    }

    @Test("a reconnect from the error callback is not ended by the failure that called it")
    func reconnectFromErrorCallback() async throws {
        let server = try LoopbackHTTPServer(status: 401, reason: "Unauthorized")
        defer { server.stop() }
        let port = try await server.start()
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: url, headers: [:]))
        defer { transport.close(code: 1000, reason: "test") }
        var events: [Event] = []
        transport.onError = { [weak transport] text in
            events.append(.error(text))
            if events.count == 1 { transport?.connect() }
        }
        transport.onClose = { events.append(.close($0.code)) }
        transport.connect()
        await eventually { events.contains(.close(1006)) }
        await eventually(timeout: .milliseconds(500)) { events.count > 3 }
        let refused = "the server refused the connection (HTTP 401)"
        // The first failure's close would have invalidated the second dial's
        // session and reported itself against it.
        #expect(events == [.error(refused), .error(refused), .close(1006)])
        #expect(server.requestHeads.count == 2)
    }

    @Test("a failure without a refusal keeps URLSession's own text")
    func otherFailuresKeepTheirText() throws {
        let url = try #require(URL(string: "ws://127.0.0.1/ws"))
        let error = URLError(.networkConnectionLost)
        #expect(URLSessionWebSocketTransport.failureText(error, response: nil) == error.localizedDescription)
        let switched = HTTPURLResponse(url: url, statusCode: 101, httpVersion: "HTTP/1.1", headerFields: nil)
        #expect(URLSessionWebSocketTransport.failureText(error, response: switched) == error.localizedDescription)
        let plain = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        #expect(URLSessionWebSocketTransport.failureText(error, response: plain) == error.localizedDescription)
    }

    @Test("the upgrade request keeps its own Cookie header, and the session keeps no cookies")
    func noCookieHandling() throws {
        let url = try #require(URL(string: "wss://mini.getbb.app/ws"))
        let request = URLSessionWebSocketTransport.urlRequest(for: TransportRequest(url: url, headers: ["Cookie": Self.cookie]))
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Cookie") == Self.cookie)
        let configuration = URLSessionWebSocketTransport.sessionConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }

    @Test("the HTTP client keeps no cookies either")
    func httpClientHasNoCookieStore() {
        let configuration = URLSessionHTTPClient.defaultConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }
}
