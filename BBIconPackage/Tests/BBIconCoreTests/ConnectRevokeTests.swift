import Foundation
import Testing
@testable import BBIconCore

/// The revoke request and its `{ok: true}` answer are written from bb
/// 0.44.0's own `revokeMachine` (the connect builtin plugin's server bundle),
/// not recorded: whether the relay lets a device revoke itself is not visible
/// in bb's code, and trying it spends a machine slot.
struct ConnectRevokeTests {
    private static let path = "/api/connect/revoke-machine"
    private static let dashboard = "remove the device by hand at getbb.app/dashboard"

    private static func pairing(machineId: String = "mach-test") throws -> Pairing {
        Pairing(
            serverURL: try #require(URL(string: "https://mini.getbb.app")),
            handle: "mini",
            machineId: machineId,
            credential: "cred-test"
        )
    }

    private func revoke(status: Int = 200, body: String) async throws -> String? {
        let http = FakeHTTPClient()
        await http.respond(Self.path, status: status, body: body)
        return await ConnectRevoke.revoke(pairing: try Self.pairing(), http: http)
    }

    // MARK: - The request

    @Test("posts the machine id to getbb.app with the machine header and no Origin")
    func sendsTheRequest() async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.path, body: #"{"ok":true}"#)
        _ = await ConnectRevoke.revoke(pairing: try Self.pairing(machineId: #"mach-"quoted"\slash"#), http: http)
        let requests = await http.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://getbb.app/api/connect/revoke-machine")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-bb-connect-machine") == "cred-test")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["machineId": #"mach-"quoted"\slash"#])
    }

    // MARK: - Answers

    @Test("a 2xx {ok: true} is a revoked pairing, and nothing to say")
    func okIsNil() async throws {
        #expect(try await revoke(body: #"{"ok":true}"#) == nil)
        #expect(try await revoke(status: 204, body: #"{"ok":true,"extra":1}"#) == nil)
    }

    @Test("a refusal names its status and points to the dashboard", arguments: [400, 401, 403, 404, 409])
    func refusalIsNamed(status: Int) async throws {
        #expect(try await revoke(status: status, body: #"{"error":"nope"}"#)
            == "Could not revoke bb Icon's pairing with mini; \(Self.dashboard). getbb.app refused it (HTTP \(status)).")
    }

    @Test("an answer of 500 or more means getbb.app could not be reached", arguments: [500, 503])
    func serverErrorIsUnreachable(status: Int) async throws {
        #expect(try await revoke(status: status, body: "")
            == "Could not revoke bb Icon's pairing with mini; \(Self.dashboard). getbb.app could not be reached: HTTP \(status)")
    }

    @Test("a transport failure means getbb.app could not be reached, naming the failure")
    func transportFailureIsUnreachable() async throws {
        let error = URLError(.timedOut)
        let text = await ConnectRevoke.revoke(pairing: try Self.pairing(), http: TransportFailureHTTPClient(error))
        #expect(text == "Could not revoke bb Icon's pairing with mini; \(Self.dashboard). getbb.app could not be reached: \(errorText(error))")
    }

    @Test("a 2xx that does not say {ok: true} is unreadable, not a success", arguments: [
        #"{"ok":false}"#, #"{}"#, #"{"ok":"true"}"#, "ok", "",
    ])
    func unexpectedBodyIsUnreadable(body: String) async throws {
        #expect(try await revoke(body: body)
            == "Could not revoke bb Icon's pairing with mini; \(Self.dashboard). getbb.app answered in a way bb Icon cannot read.")
    }

    // MARK: - The credential

    @Test("a transport failure that echoes the credential is scrubbed")
    func credentialIsScrubbedFromTransportFailure() async throws {
        let http = TransportFailureHTTPClient(CredentialEchoingError(credential: "cred-test"))
        let text = try #require(await ConnectRevoke.revoke(pairing: try Self.pairing(), http: http))
        #expect(!text.contains("cred-test"))
        #expect(text.contains("connection reset"))
    }

    @Test("no answer's text carries the credential", arguments: [
        ProbeCase(status: 403, body: "cred-test"),
        ProbeCase(status: 502, body: "cred-test"),
        ProbeCase(status: 200, body: #"{"ok":"cred-test"}"#),
    ])
    func noAnswerCarriesTheCredential(testCase: ProbeCase) async throws {
        let text = try await revoke(status: testCase.status, body: testCase.body)
        #expect(!(text ?? "").contains("cred-test"))
    }

    struct ProbeCase: Sendable, CustomTestStringConvertible {
        let status: Int
        let body: String
        var testDescription: String { "HTTP \(status) \(body)" }
    }
}
