import Foundation
import BBIconCore

/// An HTTP client that answers from a table keyed by path plus query, as
/// `/api/v1/threads?archived=false&limit=200&offset=0`, and records every
/// request. A request with no entry answers 404, so a test that forgot a
/// route fails naming it instead of hanging.
actor FakeHTTPClient: HTTPClient {
    private var routes: [String: (status: Int, body: Data)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: Data)] = [:]) {
        self.routes = routes
    }

    func respond(_ key: String, status: Int = 200, body: String) {
        routes[key] = (status, Data(body.utf8))
    }

    /// The path-plus-query key of every request, in order.
    var requestKeys: [String] {
        requests.map(Self.key)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = routes[Self.key(request)] ?? (404, Data())
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw URLError(.badURL) }
        return (body, response)
    }

    static func key(_ request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        let query = url.query(percentEncoded: true).map { "?\($0)" } ?? ""
        return url.path(percentEncoded: true) + query
    }
}
