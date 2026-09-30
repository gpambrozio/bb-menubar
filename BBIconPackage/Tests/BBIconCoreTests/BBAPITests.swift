import Foundation
import Testing
@testable import BBIconCore

struct BBAPITests {
    private static let server = URL(string: "http://127.0.0.1:38886")
    private static let projects = "/api/v1/projects"

    private static func threadsPage(_ page: Int) -> String {
        "/api/v1/threads?archived=false&limit=200&offset=\(page * BBAPI.pageSize)"
    }

    /// A JSON array of `count` minimal thread rows named `<prefix><index>`.
    private static func rows(_ count: Int, prefix: String) -> String {
        let rows = (0..<count).map { index in
            #"{"id":"\#(prefix)\#(index)","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}"#
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    private func api(_ http: FakeHTTPClient, server: URL? = BBAPITests.server) throws -> BBAPI {
        BBAPI(serverURL: try #require(server), http: http)
    }

    /// Answers the project list with one project, so a test about threads
    /// only names its pages.
    private func client() async -> FakeHTTPClient {
        let http = FakeHTTPClient()
        await http.respond(Self.projects, body: #"[{"id":"proj_a","name":"web-app"}]"#)
        return http
    }

    // MARK: - Snapshot

    @Test("fetches the projects, then pages the threads until a short page")
    func fetchesProjectsAndPagesThreads() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), body: Self.rows(200, prefix: "thr_p0_"))
        await http.respond(Self.threadsPage(1), body: Self.rows(3, prefix: "thr_p1_"))
        let snapshot = try await api(http).fetchSnapshot()
        #expect(await http.requestKeys == [
            Self.projects,
            "/api/v1/threads?archived=false&limit=200&offset=0",
            "/api/v1/threads?archived=false&limit=200&offset=200",
        ])
        #expect(await http.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(snapshot.threads.count == 203)
        #expect(snapshot.projects == [ProjectRow(id: "proj_a", name: "web-app")])
        #expect(snapshot.truncated == false)
        #expect(snapshot.decodeFailures.isEmpty)
    }

    @Test("an empty first page is a complete, empty list")
    func emptyFirstPageStops() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), body: "[]")
        let snapshot = try await api(http).fetchSnapshot()
        #expect(await http.requestKeys == [Self.projects, Self.threadsPage(0)])
        #expect(snapshot.threads.isEmpty)
        #expect(snapshot.truncated == false)
    }

    @Test("stops after 25 full pages and reports the list as truncated")
    func stopsAtMaxPagesAndReportsTruncation() async throws {
        let http = await client()
        // A 26th page exists, so only the ceiling can stop the loop.
        for page in 0...BBAPI.maxPages {
            await http.respond(Self.threadsPage(page), body: Self.rows(200, prefix: "thr_p\(page)_"))
        }
        let snapshot = try await api(http).fetchSnapshot()
        let threadRequests = await http.requestKeys.filter { $0.hasPrefix("/api/v1/threads") }
        #expect(threadRequests == (0..<BBAPI.maxPages).map(Self.threadsPage))
        #expect(snapshot.threads.count == BBAPI.maxPages * BBAPI.pageSize)
        #expect(snapshot.truncated)
    }

    @Test("a page full only because of rows that failed to decode is still full")
    func failedRowsCountTowardAFullPage() async throws {
        let http = await client()
        let good = (0..<199).map { #"{"id":"thr_\#($0)","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}"# }
        await http.respond(Self.threadsPage(0), body: "[" + (good + [#"{"id":"thr_bad"}"#]).joined(separator: ",") + "]")
        await http.respond(Self.threadsPage(1), body: Self.rows(1, prefix: "thr_p1_"))
        let snapshot = try await api(http).fetchSnapshot()
        #expect(await http.requestKeys.last == Self.threadsPage(1))
        #expect(snapshot.threads.count == 200)
        #expect(snapshot.decodeFailures.count == 1)
    }

    @Test("a thread that shifted onto the next page while paging appears once")
    func threadOnTwoPagesAppearsOnce() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), body: Self.rows(200, prefix: "thr_"))
        // A new thread pushed thr_199 down, so the next page repeats it.
        await http.respond(Self.threadsPage(1), body: #"[{"id":"thr_199","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}]"#)
        let snapshot = try await api(http).fetchSnapshot()
        #expect(snapshot.threads.count == 200)
        #expect(Set(snapshot.threads.map(\.id)).count == 200)
    }

    @Test("a trailing slash on the server URL builds the same paths")
    func serverURLWithTrailingSlashBuildsSamePaths() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), body: "[]")
        _ = try await api(http, server: URL(string: "http://127.0.0.1:38886/")).fetchSnapshot()
        #expect(await http.requestKeys == [Self.projects, Self.threadsPage(0)])
        #expect(await http.requests.first?.url?.absoluteString == "http://127.0.0.1:38886/api/v1/projects")
    }

    // MARK: - Failures

    @Test("HTTP 401 and 403 read as bb requiring authentication", arguments: [401, 403])
    func httpAuthIsAuthenticationRequired(code: Int) async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.projects, status: code, body: "")
        await #expect(throws: BBAPIError.authenticationRequired) { try await api(http).fetchSnapshot() }
        #expect(BBAPIError.authenticationRequired.message == "bb now requires authentication (HTTP 401/403); bb Icon cannot read it")
    }

    @Test("any other non-2xx status names the code and the path, without the query")
    func http500IsNamedWithPath() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), status: 500, body: "boom")
        await #expect(throws: BBAPIError.status(500, path: "/api/v1/threads")) { try await api(http).fetchSnapshot() }
        #expect(BBAPIError.status(500, path: "/api/v1/threads").message == "bb answered HTTP 500 for /api/v1/threads")
    }

    @Test("a body that is not an array is undecodable at its path")
    func nonArrayBodyIsUndecodable() async throws {
        let http = await client()
        await http.respond(Self.threadsPage(0), body: #"{"error":"nope"}"#)
        do {
            _ = try await api(http).fetchSnapshot()
            Issue.record("expected a throw")
        } catch let BBAPIError.undecodable(path, detail) {
            #expect(path == "/api/v1/threads")
            #expect(!detail.isEmpty)
            #expect(BBAPIError.undecodable(path: path, detail: detail).message
                == "bb sent something bb Icon cannot read at /api/v1/threads: \(detail)")
        }
    }

    @Test("a body that is not JSON at all is undecodable at its path")
    func nonJSONBodyIsUndecodable() async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.projects, body: "<html>")
        await #expect {
            try await api(http).fetchSnapshot()
        } throws: { error in
            guard case BBAPIError.undecodable(let path, _) = error else { return false }
            return path == "/api/v1/projects"
        }
    }

    @Test("rows that fail to decode surface as decode failures, a project's marked as one")
    func elementFailuresSurfaceAsDecodeFailures() async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.projects, body: #"[{"id":"proj_a","name":"web-app"},{"id":"proj_bad"}]"#)
        await http.respond(Self.threadsPage(0), body: """
        [{"id":"thr_good","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1},
         {"id":"thr_bad","projectId":"proj_a","status":"idle","createdAt":1}]
        """)
        let snapshot = try await api(http).fetchSnapshot()
        #expect(snapshot.threads.map(\.id) == ["thr_good"])
        #expect(snapshot.projects.map(\.id) == ["proj_a"])
        #expect(snapshot.decodeFailures == [
            "project item 1 (proj_bad): missing name",
            "item 1 (thr_bad): missing latestAttentionAt",
        ])
    }

    // MARK: - Open thread

    @Test("opening a thread POSTs {\"file\": null} to its open route")
    func openThreadPostsFileNull() async throws {
        let http = FakeHTTPClient()
        await http.respond("/api/v1/threads/thr_a/open", body: #"{"delivered":1}"#)
        try await api(http).openThread("thr_a")
        let request = try #require(await http.requests.first)
        #expect(await http.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:38886/api/v1/threads/thr_a/open")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object.count == 1)
        #expect(object["file"] is NSNull)
    }

    @Test("a thread id is one path segment, never a path")
    func openThreadEscapesTheID() async throws {
        let http = FakeHTTPClient()
        await http.respond("/api/v1/threads/a%2Fb/open", body: #"{"delivered":1}"#)
        try await api(http).openThread("a/b")
        #expect(await http.requestKeys == ["/api/v1/threads/a%2Fb/open"])
    }

    @Test("delivered to no window is an error")
    func openThreadWithNoWindowThrows() async throws {
        let http = FakeHTTPClient()
        await http.respond("/api/v1/threads/thr_a/open", body: #"{"delivered":0}"#)
        await #expect(throws: BBAPIError.noWindow) { try await api(http).openThread("thr_a") }
        #expect(BBAPIError.noWindow.message == "bb had no open window to show the thread in")
    }

    @Test("an open answer without a delivered count is undecodable at its path")
    func openThreadUndecodableAnswer() async throws {
        let http = FakeHTTPClient()
        await http.respond("/api/v1/threads/thr_a/open", body: #"{"ok":true}"#)
        await #expect(throws: BBAPIError.undecodable(path: "/api/v1/threads/thr_a/open", detail: "missing delivered")) {
            try await api(http).openThread("thr_a")
        }
    }

    @Test("an open that bb refuses names the status and path")
    func openThreadStatusIsNamed() async throws {
        let http = FakeHTTPClient()
        await http.respond("/api/v1/threads/thr_a/open", status: 404, body: "")
        await #expect(throws: BBAPIError.status(404, path: "/api/v1/threads/thr_a/open")) {
            try await api(http).openThread("thr_a")
        }
    }
}
