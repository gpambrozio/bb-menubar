import Foundation

/// Why a request to bb did not give this app what it needed. Every case names
/// itself in the error row: `/api/v1` is a bb internal, and when bb changes it
/// the tray must say so rather than go quiet.
public enum BBAPIError: MessageError, Equatable {
    case authenticationRequired
    /// A non-2xx answer other than 401/403. `path` is the URL's path, without
    /// the query, so every thread page fails with the same sentence.
    case status(Int, path: String)
    case undecodable(path: String, detail: String)
    /// The open request reached no connected bb app.
    case noWindow

    public var message: String {
        switch self {
        case .authenticationRequired: "bb now requires authentication (HTTP 401/403); bb Icon cannot read it"
        case .status(let code, let path): "bb answered HTTP \(code) for \(path)"
        case .undecodable(let path, let detail): "bb sent something bb Icon cannot read at \(path): \(detail)"
        case .noWindow: "bb had no open window to show the thread in"
        }
    }
}

/// bb 0.44.0's HTTP surface, as far as this app uses it: the snapshot reads
/// and the open-thread request `bb thread open` makes.
///
/// A server target is a base URL plus `headers`, which ride on every request:
/// none for this Mac's own bb, the relay's `x-bb-connect-machine` credential
/// for a remote one. bb Icon sets no `Origin` of its own; bb's browser guard
/// passes a request without one. A header value may be a credential, so a
/// description, debug description, or `dump` of a `BBAPI` names the header
/// fields and never their values.
public struct BBAPI: Sendable {
    /// bb pages `/api/v1/threads` and does not document its default page
    /// size, so the size is always explicit.
    public static let pageSize = 200
    /// 5,000 threads. A full last page means there may be more, and the
    /// snapshot says so rather than presenting a subset as the whole.
    public static let maxPages = 25

    private let serverURL: URL
    private let headers: [String: String]
    private let http: any HTTPClient

    public init(serverURL: URL, headers: [String: String] = [:], http: any HTTPClient) {
        self.serverURL = serverURL
        self.headers = headers
        self.http = http
    }

    /// The project list, then the thread pages. Sequential: bb is on loopback,
    /// and one request at a time keeps the paging easy to follow.
    ///
    /// Offset paging over a list that changes while it is read can repeat a
    /// row (a new thread pushes the last row of one page onto the next); the
    /// first copy wins, so the menu never gets two rows with one id. A row it
    /// skips instead is picked up by the re-fetch the same change triggers.
    public func fetchSnapshot() async throws -> BBSnapshot {
        let projects = try await getList(ProjectRow.self, path: ["api", "v1", "projects"], query: [])
        // `ThreadStore` heads these with "Some threads could not be read", so
        // a project row is the one that needs marking.
        var failures = projects.failures.map { "project " + $0 }
        var threads: [ThreadRow] = []
        var seen: Set<String> = []
        var truncated = false
        // `page < maxPages`, so `page * pageSize` is at most 4,800: no
        // server-supplied number enters the arithmetic.
        for page in 0..<Self.maxPages {
            let list = try await getList(ThreadRow.self, path: ["api", "v1", "threads"], query: [
                URLQueryItem(name: "archived", value: "false"),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(page * Self.pageSize)),
            ])
            for row in list.elements where seen.insert(row.id).inserted {
                threads.append(row)
            }
            // `LenientList` numbers items within their page, so `item 3` on
            // the second page is the 203rd row; the id beside it is what
            // names the thread.
            failures += list.failures
            // Every array slot is either an element or a failure, so a row
            // that failed to decode still counts toward a full page.
            let received = list.elements.count + list.failures.count
            if received < Self.pageSize { break }
            if page == Self.maxPages - 1 { truncated = true }
        }
        return BBSnapshot(threads: threads, projects: projects.elements, truncated: truncated, decodeFailures: failures)
    }

    /// Asks bb to show a thread in its connected app windows, as
    /// `bb thread open <id>` does. bb answers how many clients it reached;
    /// none is an error, because the click did nothing the user can see.
    ///
    /// bb 0.44.0 counts every connected `/ws` socket in `delivered`, bb Icon's
    /// own realtime socket included, so the count is an upper bound on the
    /// windows that navigated. `.noWindow` is still right when it fires, but
    /// it fires only when nothing at all is connected.
    public func openThread(_ threadId: String) async throws {
        var request = try request(path: ["api", "v1", "threads", threadId, "open"], query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"file":null}"#.utf8)
        let result = try await decode(OpenResult.self, from: request)
        guard result.delivered > 0 else { throw BBAPIError.noWindow }
    }

    private struct OpenResult: Decodable {
        let delivered: Int
    }

    private func getList<Element: Decodable>(
        _: Element.Type, path: [String], query: [URLQueryItem]
    ) async throws -> LenientList<Element> {
        try await decode(LenientList<Element>.self, from: request(path: path, query: query))
    }

    /// Every request starts here, so none leaves without the target's headers.
    private func request(path: [String], query: [URLQueryItem]) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path, query: query))
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sends the request and decodes a 2xx body. A body that does not decode
    /// at all (not JSON, not an array) fails the request, naming the path.
    private func decode<T: Decodable>(_: T.Type, from request: URLRequest) async throws -> T {
        let path = request.url?.path(percentEncoded: true) ?? ""
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw BBAPIError.authenticationRequired
        default: throw BBAPIError.status(response.statusCode, path: path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BBAPIError.undecodable(path: path, detail: failureText(error, below: 0))
        }
    }

    /// `segments` appended to the server URL's own path, each percent-encoded
    /// as one segment, so a thread id with a `/` cannot change the route.
    private func url(path segments: [String], query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var segmentAllowed = CharacterSet.urlPathAllowed
        segmentAllowed.remove("/")
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for segment in segments {
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) else {
                throw URLError(.badURL)
            }
            path += "/" + encoded
        }
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

extension BBAPI: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "BBAPI(\(serverURL.absoluteString), headers: \(redactedHeaderNames(headers)))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["serverURL": serverURL, "headers": redactedHeaderNames(headers)], displayStyle: .struct)
    }
}
