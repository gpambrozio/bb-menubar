import Foundation
import Testing
@testable import BBIconCore

/// The desktop-session request and answer are as the live relay was seen to
/// take and give them on 2026-09-30 (bb 0.44.0): `POST
/// {serverUrl}/api/connect/desktop-session` with the machine header and `{}`,
/// answered `{"cookie":{"domain":".getbb.app","expiresAt":…,"name":…,"value":…}}`,
/// and 401 once the pairing is revoked. The values here are fake.
struct ConnectSessionTests {
    private static let path = "/api/connect/desktop-session"
    private static let name = "__Secure-bb-connect.desktop_session"
    /// Shaped like the relay's (~287 characters of base64url and dots), fake.
    private static let value = "session-test." + String(repeating: "AbC-_9", count: 45)

    private static func pairing() throws -> Pairing {
        let fields = ["serverURL": "https://mini.getbb.app", "handle": "mini", "machineId": "mach-test", "credential": "cred-test"]
        return try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(fields))
    }

    private static func answer(name: String = name, value: String = value, domain: String = ".getbb.app") -> String {
        let cookie: [String: Any] = ["name": name, "value": value, "domain": domain, "expiresAt": 1_759_900_000_000]
        let data = (try? JSONSerialization.data(withJSONObject: ["cookie": cookie])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func dialHeaders(status: Int = 200, body: String) async throws -> Result<[String: String], ConnectSessionError> {
        let http = FakeHTTPClient()
        await http.respond(Self.path, status: status, body: body)
        let pairing = try Self.pairing()
        do throws(ConnectSessionError) {
            return .success(try await ConnectSession.dialHeaders(pairing: pairing, http: http))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - The request

    @Test("posts {} to the paired server's relay with the machine header, and no Origin or Cookie")
    func sendsTheRequest() async throws {
        let http = FakeHTTPClient()
        await http.respond(Self.path, body: Self.answer())
        _ = try await ConnectSession.dialHeaders(pairing: try Self.pairing(), http: http)
        let requests = await http.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://mini.getbb.app/api/connect/desktop-session")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-bb-connect-machine") == "cred-test")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == Data("{}".utf8))
    }

    // MARK: - Answers

    @Test("the relay's session cookie becomes the upgrade's Cookie header")
    func cookieBecomesHeader() async throws {
        let headers = try await dialHeaders(body: Self.answer()).get()
        #expect(headers == ["Cookie": "\(Self.name)=\(Self.value)"])
    }

    @Test("a domain in another case, extra fields, and the longest value are accepted")
    func lenientWhereHarmless() async throws {
        let longest = String(repeating: "a", count: 4096)
        #expect(try await dialHeaders(body: Self.answer(value: longest)).get() == ["Cookie": "\(Self.name)=\(longest)"])
        #expect(try await dialHeaders(body: Self.answer(domain: ".GetBB.app")).get() == ["Cookie": "\(Self.name)=\(Self.value)"])
        let extra = #"{"cookie":{"name":"\#(Self.name)","value":"v1","domain":".getbb.app","path":"/","sameSite":"lax"},"other":1}"#
        #expect(try await dialHeaders(body: extra).get() == ["Cookie": "\(Self.name)=v1"])
    }

    @Test("a refused credential is the revoked pairing, in the probe's words", arguments: [401, 403])
    func refusedIsRevoked(status: Int) async throws {
        let result = try await dialHeaders(status: status, body: #"{"error":"unauthorized"}"#)
        #expect(result == .failure(.revoked(handle: "mini")))
        #expect(ConnectSessionError.revoked(handle: "mini").message == ConnectHealthFinding.revoked.message(handle: "mini"))
    }

    @Test("any other refusal is named with its status")
    func otherRefusalsAreNamed() async throws {
        let prefix = "bb live updates: could not start a session with getbb.app: "
        let unavailable = try await dialHeaders(status: 503, body: "<html>down</html>")
        #expect(unavailable == .failure(.failed("HTTP 503")))
        #expect((try? unavailable.get()) == nil)
        #expect(ConnectSessionError.failed("HTTP 503").message == prefix + "HTTP 503")
        #expect(try await dialHeaders(status: 404, body: "") == .failure(.failed("getbb.app answered HTTP 404")))
        #expect(try await dialHeaders(status: 302, body: "") == .failure(.failed("getbb.app answered HTTP 302")))
    }

    @Test("no answer is named, without the credential")
    func transportFailureIsScrubbed() async throws {
        let http = TransportFailureHTTPClient(CredentialEchoingError(credential: "cred-test"))
        let pairing = try Self.pairing()
        do throws(ConnectSessionError) {
            _ = try await ConnectSession.dialHeaders(pairing: pairing, http: http)
            Issue.record("expected a failure")
        } catch {
            #expect(error == .failed("connection reset while sending \(Pairing.redacted)"))
            #expect(!error.message.contains("cred-test"))
        }
    }

    /// Each bad value carries `LEAK`, so a message that quotes the answer is
    /// caught.
    @Test("an answer that is not exactly the expected cookie is refused, naming the field and never the value", arguments: [
        ("not json LEAK", "the answer is not {cookie: {name, value, domain}}"),
        (#"["LEAK"]"#, "the answer is not {cookie: {name, value, domain}}"),
        (#"{"session":"LEAK"}"#, "the answer has no cookie object"),
        (#"{"cookie":"LEAK"}"#, "the answer has no cookie object"),
        (answer(name: "other_LEAK"), "the cookie is not named __Secure-bb-connect.desktop_session"),
        (#"{"cookie":{"value":"LEAK","domain":".getbb.app"}}"#, "the cookie is not named __Secure-bb-connect.desktop_session"),
        (answer(domain: ".evil-LEAK.test"), "the cookie's domain is not .getbb.app"),
        (answer(domain: "getbb.app"), "the cookie's domain is not .getbb.app"),
        (#"{"cookie":{"name":"__Secure-bb-connect.desktop_session","value":"LEAK"}}"#, "the cookie's domain is not .getbb.app"),
        (answer(value: ""), valueRefusal),
        (answer(value: "LEAK;other=1"), valueRefusal),
        (answer(value: "LEAK,other"), valueRefusal),
        (answer(value: "LEAK other"), valueRefusal),
        (answer(value: "LEAK\tother"), valueRefusal),
        (answer(value: "LEAK\r\nX-Evil: 1"), valueRefusal),
        (answer(value: "\"LEAK\""), valueRefusal),
        (answer(value: "LEAK\\"), valueRefusal),
        (answer(value: "LEAKé"), valueRefusal),
        (answer(value: "LEAK" + String(repeating: "a", count: 4093)), valueRefusal),
        (#"{"cookie":{"name":"__Secure-bb-connect.desktop_session","value":7,"domain":".getbb.app"}}"#, valueRefusal),
    ])
    func badAnswersAreRefused(body: String, detail: String) async throws {
        let result = try await dialHeaders(body: body)
        #expect(result == .failure(.failed(detail)))
        if case .failure(let error) = result {
            #expect(!error.message.contains("LEAK"))
        }
    }

    private static let valueRefusal = "the cookie's value is not 1 to 4096 cookie-safe characters"
}
