import Foundation

/// Why a desktop session could not be had. Messages never carry the answer's
/// body, the cookie's value, or the credential.
public enum ConnectSessionError: MessageError, Equatable, Sendable {
    /// The relay refused the machine credential (401/403): the pairing has
    /// been revoked, which is how the probe names it too.
    case revoked(handle: String)
    /// No answer, another refusal, or an answer that is not a session cookie
    /// bb Icon can send. The detail says which.
    case failed(String)

    public var message: String {
        switch self {
        case .revoked(let handle): ConnectHealthFinding.revokedMessage(handle: handle)
        case .failed(let detail): "bb live updates: could not start a session with getbb.app: \(detail)"
        }
    }
}

/// The session cookie the getbb.app relay requires on a `/ws` upgrade.
///
/// The relay takes the machine credential in `x-bb-connect-machine` on HTTP
/// requests, but refuses it on a WebSocket upgrade (HTTP 401). What it accepts
/// there is a desktop session: `POST {serverUrl}/api/connect/desktop-session`
/// with the machine header and `{}` answers
/// `{"cookie": {"name", "value", "domain", "expiresAt"}}`, and an upgrade that
/// sends `Cookie: <name>=<value>` opens. Established against the live relay on
/// 2026-09-30 (bb 0.44.0); bb.app's own client is the model.
///
/// A session is minted before every remote dial rather than kept: the dial
/// already waits out the reconnect backoff, a revoked pairing kills existing
/// sessions anyway, and nothing has to decide when one has expired.
///
/// The cookie's value is a credential like the machine credential it was
/// minted with. It goes into the upgrade's `Cookie` header and nowhere else.
public enum ConnectSession {
    static let path = "/api/connect/desktop-session"
    /// The only cookie bb Icon will send. A different name in the answer is a
    /// relay bb Icon does not know, and is refused rather than guessed at.
    public static let cookieName = "__Secure-bb-connect.desktop_session"
    static let cookieDomain = ".getbb.app"
    /// Far above the ~290 characters the relay mints; it bounds what goes
    /// into a request header.
    static let maxValueLength = 4096

    /// The extra headers for one `/ws` upgrade to `pairing`'s server: its
    /// session cookie, freshly minted.
    public static func dialHeaders(pairing: Pairing, http: any HTTPClient) async throws(ConnectSessionError) -> [String: String] {
        let value = try await mint(pairing: pairing, http: http)
        return ["Cookie": "\(cookieName)=\(value)"]
    }

    /// Asks the relay for a desktop session and returns the cookie's value,
    /// checked to be exactly the cookie bb Icon expects and safe to put in a
    /// header.
    static func mint(pairing: Pairing, http: any HTTPClient) async throws(ConnectSessionError) -> String {
        guard let url = ConnectHealth.relayURL(pairing.serverURL, path: path) else {
            throw .failed("the paired server's address is not a usable URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(pairing.credential, forHTTPHeaderField: ConnectHealth.credentialHeader)
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            throw .failed(scrubbing(pairing.credential, from: errorText(error)))
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw .revoked(handle: pairing.handle)
        case 500...: throw .failed("HTTP \(response.statusCode)")
        default: throw .failed("getbb.app answered HTTP \(response.statusCode)")
        }

        // The answer holds the cookie's value, so no decoding error's detail,
        // and none of the answer's fields, reach the message: each failure
        // names the field it is about.
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw .failed("the answer is not {cookie: {name, value, domain}}")
        }
        guard let cookie = answer.cookie else { throw .failed("the answer has no cookie object") }
        guard cookie.name == cookieName else { throw .failed("the cookie is not named \(cookieName)") }
        guard cookie.domain?.lowercased() == cookieDomain else { throw .failed("the cookie's domain is not \(cookieDomain)") }
        guard let value = cookie.value, isCookieValue(value) else {
            throw .failed("the cookie's value is not 1 to \(maxValueLength) cookie-safe characters")
        }
        return value
    }

    /// RFC 6265's `cookie-octet`, one to `maxValueLength` of them: visible
    /// ASCII except `"`, `,`, `;`, and `\`. No whitespace, so the value
    /// cannot split the header or add a cookie of its own.
    static func isCookieValue(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...maxValueLength).contains(bytes.count) && bytes.allSatisfy { byte in
            (0x21...0x7E).contains(byte) && byte != 0x22 && byte != 0x2C && byte != 0x3B && byte != 0x5C
        }
    }

    /// Every field optional and read without throwing, so a missing or
    /// mistyped one is named rather than failing the whole answer.
    private struct Answer: Decodable {
        let cookie: Cookie?

        private enum CodingKeys: String, CodingKey { case cookie }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cookie = try? container.decode(Cookie.self, forKey: .cookie)
        }
    }

    private struct Cookie: Decodable {
        let name: String?
        let value: String?
        let domain: String?

        private enum CodingKeys: String, CodingKey { case name, value, domain }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decode(String.self, forKey: .name)
            value = try? container.decode(String.self, forKey: .value)
            domain = try? container.decode(String.self, forKey: .domain)
        }
    }
}
