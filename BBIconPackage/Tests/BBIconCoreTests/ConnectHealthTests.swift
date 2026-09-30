import Foundation
import Testing
@testable import BBIconCore

/// The `/api/connect/servers` answers are written from bb 0.44.0's own
/// client (`@bb/connect-client/src/list-servers.ts`): `{servers: [{handle,
/// name, live}]}`, 401/403 for a credential the relay no longer accepts, any
/// other non-2xx a network failure. Recording the relay's real answers needs
/// a paired device, so these are from the source, not a capture.
struct ConnectHealthTests {
    private static let path = "/api/connect/servers"

    /// Built by decoding, the way the Keychain item is read, so the pairing
    /// passes the same checks a stored one does.
    private static func pairing(serverURL: String = "https://mini.getbb.app") throws -> Pairing {
        let fields = ["serverURL": serverURL, "handle": "mini", "machineId": "mach-test", "credential": "cred-test"]
        return try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(fields))
    }

    private static func servers(_ entries: (handle: String, live: Bool)...) -> String {
        let rows = entries.map { #"{"handle":"\#($0.handle)","name":"\#($0.handle) Mac","live":\#($0.live)}"# }
        return #"{"servers":["# + rows.joined(separator: ",") + "]}"
    }

    private func probe(status: Int = 200, body: String) async throws -> ConnectHealthFinding {
        let http = FakeHTTPClient()
        await http.respond(Self.path, status: status, body: body)
        return await ConnectHealth.probe(pairing: try Self.pairing(), http: http)
    }

    // MARK: - The request

    @Test("asks the paired server's relay for the account's servers, with the machine header and no Origin")
    func sendsTheRequest() async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.path, body: Self.servers(("mini", true)))
        _ = await ConnectHealth.probe(pairing: try Self.pairing(), http: http)
        let requests = await http.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://mini.getbb.app/api/connect/servers")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-bb-connect-machine") == "cred-test")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.httpBody == nil)
    }

    @Test("the probe goes to the server's origin, with or without a trailing slash", arguments: [
        "https://mini.getbb.app",
        "https://mini.getbb.app/",
    ])
    func probeURLIsOriginOnly(serverURL: String) async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.path, body: Self.servers(("mini", true)))
        _ = await ConnectHealth.probe(pairing: try Self.pairing(serverURL: serverURL), http: http)
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://mini.getbb.app/api/connect/servers")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// `Pairing` refuses a server URL with anything past its origin, so these
    /// cannot reach `probe`; the URL builder still takes only the origin, so
    /// a path, query, fragment, or user info could not move the request or
    /// turn into an `Authorization` if that check ever loosened.
    @Test("the probe URL is built from the server's origin alone", arguments: [
        "https://mini.getbb.app",
        "https://mini.getbb.app/",
        "https://mini.getbb.app/x/y?q=1#f",
        "https://u:p@mini.getbb.app",
    ])
    func serversURLIsOriginOnly(serverURL: String) throws {
        let server = try #require(URL(string: serverURL))
        let url = try #require(ConnectHealth.serversURL(server))
        #expect(url.absoluteString == "https://mini.getbb.app/api/connect/servers")
        #expect(url.user() == nil)
        #expect(url.password() == nil)
    }

    // MARK: - Classification

    @Test("401 and 403 mean the relay no longer accepts the pairing", arguments: [401, 403])
    func refusedIsRevoked(status: Int) async throws {
        #expect(try await probe(status: status, body: "<html>Unauthorized</html>") == .revoked)
    }

    @Test("the paired server listed as live is live")
    func liveEntryIsLive() async throws {
        #expect(try await probe(body: Self.servers(("other", false), ("mini", true))) == .live)
    }

    @Test("the paired server listed as not live is offline, whatever the account's other servers say")
    func notLiveEntryIsOffline() async throws {
        #expect(try await probe(body: Self.servers(("other", true), ("mini", false))) == .offline)
    }

    @Test("the handle is matched as a DNS label, ignoring case")
    func handleMatchIgnoresCase() async throws {
        #expect(try await probe(body: Self.servers(("MINI", true))) == .live)
    }

    @Test("a server missing from the account's list is offline", arguments: [
        ServersBody(#"{"servers":[]}"#),
        ServersBody(#"{"servers":[{"handle":"other","name":"Other","live":true}]}"#),
        ServersBody(#"{"servers":[{"handle":"other"},"junk",{"live":true},{"handle":7,"live":true}]}"#),
    ])
    func missingEntryIsOffline(body: ServersBody) async throws {
        #expect(try await probe(body: body.json) == .offline)
    }

    @Test("malformed rows for other servers are ignored; the paired server's own row decides", arguments: [
        ProbeCase(status: 200, body: #"{"servers":[{"handle":"other"},{"handle":"mini","name":"Mini","live":true}]}"#),
        ProbeCase(status: 200, body: #"{"servers":["junk",{"live":false},{"handle":"mini","live":true},{"handle":7}]}"#),
        ProbeCase(status: 200, body: #"{"servers":[{"handle":"other","live":"no"},{"handle":"mini","live":true}]}"#),
    ])
    func malformedUnrelatedRowsAreIgnored(testCase: ProbeCase) async throws {
        #expect(try await probe(body: testCase.body) == .live)
    }

    @Test("an answer of 500 or more means getbb.app could not be reached", arguments: [500, 502, 503])
    func serverErrorIsUnreachable(status: Int) async throws {
        #expect(try await probe(status: status, body: "") == .unreachable("HTTP \(status)"))
    }

    @Test("any other non-2xx answer is also unreachable, as bb's own client classifies it", arguments: [301, 400, 404, 429])
    func otherStatusIsUnreachable(status: Int) async throws {
        #expect(try await probe(status: status, body: "") == .unreachable("getbb.app answered HTTP \(status)"))
    }

    @Test("a transport failure is unreachable, naming the failure")
    func transportFailureIsUnreachable() async throws {
        let http = TransportFailureHTTPClient(URLError(.notConnectedToInternet))
        let finding = await ConnectHealth.probe(pairing: try Self.pairing(), http: http)
        #expect(finding == .unreachable(errorText(URLError(.notConnectedToInternet))))
        #expect(await http.requests.count == 1)
    }

    /// Foundation words its own decoding failures, so beyond its standard
    /// "not valid JSON" the test holds the part bb Icon writes: which field,
    /// under which path. The paired server's own row being malformed is
    /// unreadable, not offline: the answer does not say which it is.
    @Test("a 2xx body that is not the expected JSON is unreadable, naming the field", arguments: [
        UnreadableCase(body: "<html>hello</html>", detailPrefix: "The given data was not valid JSON"),
        UnreadableCase(body: #"{"servers":"cred-test"}"#, detailPrefix: "servers: "),
        UnreadableCase(body: "{}", detailPrefix: "missing servers"),
        UnreadableCase(body: #"{"servers":[{"handle":"mini"}]}"#, detailPrefix: "missing servers.[0].live"),
        UnreadableCase(body: #"{"servers":[{"handle":"mini","live":"yes"}]}"#, detailPrefix: "servers.[0].live: "),
        UnreadableCase(body: #"{"servers":[{"handle":"other","live":true},{"handle":"MINI","live":null}]}"#, detailPrefix: "servers.[1].live: "),
    ])
    func badBodyIsUnreadable(testCase: UnreadableCase) async throws {
        let finding = try await probe(body: testCase.body)
        guard case .unreadable(let detail) = finding else {
            Issue.record("expected unreadable, got \(finding)")
            return
        }
        #expect(detail.hasPrefix(testCase.detailPrefix))
    }

    // MARK: - Messages

    @Test("each finding names itself with the design's error-row text")
    func messages() {
        #expect(ConnectHealthFinding.revoked.message(handle: "mini")
            == "bb Connect no longer accepts bb Icon's pairing with mini. Pair again, or forget it.")
        #expect(ConnectHealthFinding.offline.message(handle: "mini")
            == "mini is offline — the Mac running it may be asleep or bb may be closed there.")
        #expect(ConnectHealthFinding.unreachable("HTTP 502").message(handle: "mini")
            == "getbb.app could not be reached: HTTP 502")
        #expect(ConnectHealthFinding.unreadable("missing servers").message(handle: "mini")
            == "getbb.app sent something bb Icon cannot read at /api/connect/servers: missing servers")
        #expect(ConnectHealthFinding.live.message(handle: "mini") == nil)
    }

    // MARK: - The credential

    @Test("a transport failure that echoes the credential is scrubbed before it becomes a finding")
    func credentialIsScrubbedFromTransportFailure() async throws {
        let http = TransportFailureHTTPClient(CredentialEchoingError(credential: "cred-test"))
        let finding = await ConnectHealth.probe(pairing: try Self.pairing(), http: http)
        guard case .unreachable(let detail) = finding else {
            Issue.record("expected unreachable, got \(finding)")
            return
        }
        #expect(!detail.contains("cred-test"))
        #expect(detail.contains("connection reset"))
        #expect(!String(describing: finding).contains("cred-test"))
        #expect(!(finding.message(handle: "mini") ?? "").contains("cred-test"))
    }

    @Test("no finding's text carries the credential", arguments: [
        ProbeCase(status: 401, body: ""),
        ProbeCase(status: 200, body: #"{"servers":[{"handle":"mini","name":"Mini","live":false}]}"#),
        ProbeCase(status: 200, body: #"{"servers":[{"handle":"mini","name":"Mini","live":true}]}"#),
        ProbeCase(status: 502, body: "cred-test"),
        ProbeCase(status: 200, body: #"{"servers":"cred-test"}"#),
    ])
    func noFindingCarriesTheCredential(testCase: ProbeCase) async throws {
        let finding = try await probe(status: testCase.status, body: testCase.body)
        #expect(!String(describing: finding).contains("cred-test"))
        #expect(!(finding.message(handle: "mini") ?? "").contains("cred-test"))
    }

    // MARK: - Arguments

    struct ServersBody: Sendable, CustomTestStringConvertible {
        let json: String
        init(_ json: String) { self.json = json }
        var testDescription: String { json }
    }

    struct UnreadableCase: Sendable, CustomTestStringConvertible {
        let body: String
        let detailPrefix: String
        var testDescription: String { body }
    }

    struct ProbeCase: Sendable, CustomTestStringConvertible {
        let status: Int
        let body: String
        var testDescription: String { "HTTP \(status) \(body)" }
    }
}
