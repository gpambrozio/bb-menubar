import Foundation
import Testing
@testable import BBIconCore

/// The answers below are written from bb 0.44.0's own client,
/// `packages/connect-client/src/redeem-machine.ts` in bb.app's main bundle,
/// not recorded: recording one means minting and spending a real code.
struct ConnectPairingTests {
    private static let redeemPath = "/api/connect/redeem-machine"
    private static let credential = "cred-test-never-shown"

    private static func answer(serverUrl: String?) -> String {
        let url = serverUrl.map { #""\#($0)""# } ?? "null"
        return #"{"credential":"\#(credential)","machineId":"m-test","serverUrl":\#(url)}"#
    }

    private func redeem(status: Int = 200, body: String, code: String = "ABCD-1234") async throws -> (Pairing, FakeHTTPClient) {
        let http = FakeHTTPClient()
        await http.respond(Self.redeemPath, status: status, body: body)
        return (try await ConnectPairing.redeem(code: code, http: http), http)
    }

    /// The error `redeem` throws for this answer, or nil if it did not throw
    /// one of its own.
    private func redeemError(status: Int, body: String) async -> ConnectPairingError? {
        do {
            _ = try await redeem(status: status, body: body)
            return nil
        } catch {
            return error as? ConnectPairingError
        }
    }

    // MARK: - Pasted input

    @Test("reads the code from a bare code or from bb's machine-code JSON", arguments: [
        ("  ABCD-1234 \n", "ABCD-1234"),
        (#"{"code":"ABCD-1234","serverUrl":"https://mini.getbb.app","apex":"https://getbb.app","expiresAt":"2026-09-30T10:00:00Z"}"#, "ABCD-1234"),
        (#"  {"code":" ABCD-1234 ","apex":"https://getbb.app/"}  "#, "ABCD-1234"),
        (#"{"code":"ABCD-1234"}"#, "ABCD-1234"),
        (#"{"code":"ABCD-1234","apex":null}"#, "ABCD-1234"),
    ])
    func parsesInput(input: String, code: String) throws {
        #expect(try ConnectPairing.parseInput(input) == code)
    }

    @Test("names what is wrong with input it cannot use", arguments: [
        ("", ConnectPairingError.emptyInput),
        ("  \n\t ", .emptyInput),
        (#"{"code":"ABCD-1234","apex":"https://evil.example"}"#, .foreignApex("https://evil.example")),
        (#"{"code":"ABCD-1234","apex":"http://getbb.app"}"#, .foreignApex("http://getbb.app")),
        (#"{"code":"ABCD-1234","apex":"https://getbb.app.evil.example"}"#, .foreignApex("https://getbb.app.evil.example")),
        (#"{"serverUrl":"https://mini.getbb.app","apex":"https://getbb.app"}"#, .missingCode),
        (#"{"code":"  "}"#, .missingCode),
        (#"{"code":42}"#, .unreadableInput),
        (#"{"code":"ABCD-1234""#, .unreadableInput),
    ])
    func refusesInput(input: String, expected: ConnectPairingError) {
        #expect(throws: expected) { try ConnectPairing.parseInput(input) }
    }

    // MARK: - Redeem

    @Test("redeems at getbb.app with the code alone, and nothing else in the request")
    func redeemRequestIsExact() async throws {
        let (_, http) = try await redeem(body: Self.answer(serverUrl: "https://example-mini.getbb.app"))
        let requests = await http.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.absoluteString == "https://getbb.app/api/connect/redeem-machine")
        #expect(request.httpMethod == "POST")
        #expect(request.allHTTPHeaderFields?.count == 1)
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["code": "ABCD-1234"])
    }

    @Test("a good answer becomes a pairing named by its server's label", arguments: [
        ("https://example-mini.getbb.app", "example-mini"),
        ("https://example-mini.getbb.app/", "example-mini"),
        ("https://Mini.GetBB.app", "mini"),
    ])
    func redeemBuildsPairing(serverUrl: String, handle: String) async throws {
        let (pairing, _) = try await redeem(body: Self.answer(serverUrl: serverUrl))
        let expected = try Pairing(
            serverURL: try #require(URL(string: "https://\(handle).getbb.app")),
            handle: handle,
            machineId: "m-test",
            credential: Self.credential
        )
        #expect(pairing == expected)
    }

    @Test("names each refusal as bb does", arguments: [
        (403, #"{"error":"machine-limit"}"#, ConnectPairingError.machineLimit),
        (400, #"{"error":"already-used"}"#, .alreadyUsed),
        (409, #"{}"#, .alreadyUsed),
        (409, "<html>Conflict</html>", .alreadyUsed),
        (400, #"{"error":"expired"}"#, .expired),
        (410, "", .expired),
        (500, #"{"error":"boom"}"#, .unreachable("HTTP 500")),
        (503, "<html>Service Unavailable</html>", .unreachable("HTTP 503")),
        (400, #"{"error":"invalid-code"}"#, .refused),
        (401, "", .refused),
        (404, "", .refused),
        // Where the wire error and the status disagree, bb's order decides.
        (409, #"{"error":"machine-limit"}"#, .machineLimit),
        (500, #"{"error":"machine-limit"}"#, .machineLimit),
        (410, #"{"error":"already-used"}"#, .alreadyUsed),
        (409, #"{"error":"expired"}"#, .alreadyUsed),
        (503, #"{"error":"expired"}"#, .expired),
        (200, "not json", .unreadableAnswer),
        (200, #"{"credential":"cred-test-never-shown","machineId":"m-test"}"#, .unreadableAnswer),
        (200, #"{"credential":"","machineId":"m-test","serverUrl":"https://mini.getbb.app"}"#, .unreadableAnswer),
        (200, #"{"credential":"cred-test-never-shown","machineId":"","serverUrl":"https://mini.getbb.app"}"#, .unreadableAnswer),
    ])
    func redeemRefusals(status: Int, body: String, expected: ConnectPairingError) async {
        #expect(await redeemError(status: status, body: body) == expected)
    }

    /// The credential goes into a request header, so anything but a plain
    /// token could split or corrupt the header.
    @Test("refuses a credential or machine id that is not a header-safe token", arguments: [
        (#"cred test"#, "m-test"),
        (#"cred-test\r\nx-evil: 1"#, "m-test"),
        (#"cred-t\u00e9st"#, "m-test"),
        (#"cred-test\t"#, "m-test"),
        (String(repeating: "c", count: 4097), "m-test"),
        ("cred-test", #"m test"#),
        ("cred-test", #"m-test\n"#),
        ("cred-test", String(repeating: "m", count: 4097)),
    ])
    func redeemRefusesUnsafeTokens(credential: String, machineId: String) async {
        let body = #"{"credential":"\#(credential)","machineId":"\#(machineId)","serverUrl":"https://mini.getbb.app"}"#
        #expect(await redeemError(status: 200, body: body) == .unreadableAnswer)
    }

    @Test("a 4096-character credential is still a credential")
    func redeemAcceptsLongestToken() async throws {
        let credential = String(repeating: "c", count: 4096)
        let body = #"{"credential":"\#(credential)","machineId":"m-test","serverUrl":"https://mini.getbb.app"}"#
        let (pairing, _) = try await redeem(body: body)
        #expect(pairing.credential == credential)
    }

    @Test("refuses a server that is not one label under https://getbb.app", arguments: [
        nil,
        "https://mini.evil.example",
        "http://mini.getbb.app",
        "wss://mini.getbb.app",
        "https://a.b.getbb.app",
        "https://.getbb.app",
        "https://getbb.app",
        "https://evilgetbb.app",
        "https://mini.getbb.app.evil.example",
        "https://mini.getbb.app:8443",
        "https://mini.getbb.app/elsewhere",
        "https://mini.getbb.app?x=1",
        "https://user@mini.getbb.app",
        "https://mini_1.getbb.app",
        "mini.getbb.app",
        "",
    ] as [String?])
    func redeemRefusesForeignServer(serverUrl: String?) async {
        let error = await redeemError(status: 200, body: Self.answer(serverUrl: serverUrl))
        #expect(error == .unreadableAnswer)
        // The credential was in that answer; it must not be in what the
        // user is shown about it.
        #expect(error.map { !$0.message.contains(Self.credential) } ?? false)
        #expect(!String(reflecting: error).contains(Self.credential))
    }

    @Test("a request that never reaches getbb.app is named with its cause")
    func redeemTransportFailure() async {
        let failure = URLError(.notConnectedToInternet)
        do {
            _ = try await ConnectPairing.redeem(code: "ABCD-1234", http: FailingHTTPClient(error: failure))
            Issue.record("redeem succeeded without an answer")
        } catch {
            #expect(error as? ConnectPairingError == .unreachable(errorText(failure)))
        }
    }

    @Test("an empty code is refused before anything is sent")
    func redeemEmptyCode() async {
        let http = FakeHTTPClient()
        await #expect(throws: ConnectPairingError.emptyInput) {
            try await ConnectPairing.redeem(code: "  ", http: http)
        }
        #expect(await http.requests.isEmpty)
    }

    @Test("the pairing messages are the design's, word for word", arguments: [
        (ConnectPairingError.machineLimit, "Your bb Connect account has no free machine slots. Revoke a device you no longer use at getbb.app/dashboard, then try again."),
        (.alreadyUsed, "That code was already used. Make a new one."),
        (.expired, "That code has expired — codes last 10 minutes. Make a new one."),
        (.unreachable("HTTP 502"), "getbb.app could not be reached: HTTP 502"),
        (.refused, "getbb.app did not accept that code."),
        (.unreadableAnswer, "getbb.app answered in a way bb Icon cannot read."),
    ])
    func messages(error: ConnectPairingError, message: String) {
        #expect(error.message == message)
        #expect(errorText(error) == message)
    }

    // MARK: - The pairing value

    @Test("a pairing never shows its credential when printed, dumped, or reflected")
    func pairingRedactsCredential() throws {
        let pairing = try Pairing(
            serverURL: try #require(URL(string: "https://mini.getbb.app")),
            handle: "mini",
            machineId: "m-test",
            credential: Self.credential
        )
        var dumped = ""
        dump(pairing, to: &dumped)
        let renderings = [
            String(describing: pairing),
            String(reflecting: pairing),
            "\(pairing)",
            String(describing: [pairing]),
            String(describing: Optional(pairing)),
            dumped,
            Mirror(reflecting: pairing).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", "),
        ]
        for rendering in renderings {
            #expect(!rendering.contains(Self.credential), "a rendering of the pairing leaked its credential")
            #expect(rendering.contains("mini"))
        }
    }

    @Test("a pairing survives its storage encoding whole")
    func pairingRoundTrips() throws {
        let pairing = try Pairing(
            serverURL: try #require(URL(string: "https://mini.getbb.app")),
            handle: "mini",
            machineId: "m-test",
            credential: Self.credential
        )
        let data = try JSONEncoder().encode(pairing)
        #expect(try JSONDecoder().decode(Pairing.self, from: data) == pairing)
    }

    @Test("a pairing is only ever for https://<handle>.getbb.app, with header-safe tokens", arguments: [
        ("https://evil.example", "mini", "m-test", "cred-test", PairingValidationError.serverURL),
        ("https://other.getbb.app", "mini", "m-test", "cred-test", .serverURL),
        ("http://mini.getbb.app", "mini", "m-test", "cred-test", .serverURL),
        ("https://mini.getbb.app:8443", "mini", "m-test", "cred-test", .serverURL),
        ("https://mini.getbb.app/elsewhere", "mini", "m-test", "cred-test", .serverURL),
        ("https://Mini.getbb.app", "Mini", "m-test", "cred-test", .serverURL),
        ("https://a.b.getbb.app", "a.b", "m-test", "cred-test", .serverURL),
        ("https://mini.getbb.app", "mini", "", "cred-test", .machineId),
        ("https://mini.getbb.app", "mini", "m test", "cred-test", .machineId),
        ("https://mini.getbb.app", "mini", "m-test", "", .credential),
        ("https://mini.getbb.app", "mini", "m-test", "cred\r\ntest", .credential),
        ("https://mini.getbb.app", "mini", "m-test", "cr\u{e9}d", .credential),
        ("https://mini.getbb.app", "mini", "m-test", String(repeating: "c", count: 4097), .credential),
    ])
    func pairingRefusesInvalidFields(
        serverURL: String, handle: String, machineId: String, credential: String, expected: PairingValidationError
    ) throws {
        let url = try #require(URL(string: serverURL))
        #expect(throws: expected) {
            try Pairing(serverURL: url, handle: handle, machineId: machineId, credential: credential)
        }
    }

    @Test("a stored pairing that names a foreign server does not decode")
    func pairingDecodingValidates() throws {
        let good = #"{"serverURL":"https://mini.getbb.app","handle":"mini","machineId":"m-test","credential":"cred-test"}"#
        #expect(try JSONDecoder().decode(Pairing.self, from: Data(good.utf8)).handle == "mini")
        for planted in [
            #"{"serverURL":"https://evil.example","handle":"mini","machineId":"m-test","credential":"cred-test"}"#,
            #"{"serverURL":"https://mini.getbb.app","handle":"mini","machineId":"m-test","credential":"cred\r\ntest"}"#,
        ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Pairing.self, from: Data(planted.utf8)) }
        }
    }
}

/// An HTTP client whose every request fails before an answer, as a request
/// to an unreachable host does.
private struct FailingHTTPClient: HTTPClient {
    let error: URLError

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}
