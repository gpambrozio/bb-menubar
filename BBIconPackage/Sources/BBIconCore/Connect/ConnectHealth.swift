import Foundation

/// What the bb Connect relay says about the paired server, asked when a fetch
/// or the socket to it fails. A remote connection can fail in ways a loopback
/// one cannot, and each is named rather than shown as the raw failure.
public enum ConnectHealthFinding: Equatable, Sendable {
    /// The relay refused the machine credential (401/403).
    case revoked
    /// The account's server list has this server not live, or not at all.
    case offline
    /// No answer, or a non-2xx that bb's own client treats as a network
    /// failure. The detail never carries the credential.
    case unreachable(String)
    /// The server is live, so the original failure is the one to show.
    case live
    /// A 2xx whose body is not `{servers: [{handle, live}]}`, naming the field.
    case unreadable(String)

    /// The error row for this finding, from the design's "Naming what goes
    /// wrong" table. `.live` has none: the original error stands.
    public func message(handle: String) -> String? {
        switch self {
        case .revoked:
            "bb Connect no longer accepts bb Icon's pairing with \(handle). Pair again, or forget it."
        case .offline:
            "\(handle) is offline — the Mac running it may be asleep or bb may be closed there."
        case .unreachable(let detail):
            "getbb.app could not be reached: \(detail)"
        case .unreadable(let detail):
            "getbb.app sent something bb Icon cannot read at \(ConnectHealth.path): \(detail)"
        case .live:
            nil
        }
    }
}

/// The `/api/connect/servers` probe. bb 0.44.0's own client for it is
/// `@bb/connect-client/src/list-servers.ts`; the request, the answer's shape,
/// and which statuses mean what are copied from there.
public enum ConnectHealth {
    static let path = "/api/connect/servers"
    static let credentialHeader = "x-bb-connect-machine"

    /// Asks the paired server's relay which of the account's servers are
    /// live. Never throws: every outcome is a finding.
    public static func probe(pairing: Pairing, http: any HTTPClient) async -> ConnectHealthFinding {
        guard let url = serversURL(pairing.serverURL) else {
            return .unreachable("the paired server's address is not a usable URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(pairing.credential, forHTTPHeaderField: credentialHeader)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            return .unreachable(scrubbing(pairing.credential, from: errorText(error)))
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: return .revoked
        default: return .unreachable("HTTP \(response.statusCode)")
        }

        let servers: [ServerEntry]
        do {
            servers = try JSONDecoder().decode(ServersResponse.self, from: data).servers
        } catch {
            return .unreadable(scrubbing(pairing.credential, from: failureText(error, below: 0)))
        }
        // Handles are DNS labels, which compare without case.
        let entry = servers.first { $0.handle.lowercased() == pairing.handle.lowercased() }
        return entry?.live == true ? .live : .offline
    }

    /// bb's client strictly validates every entry; only the two fields this
    /// app reads are required here, and anything else is ignored.
    private struct ServersResponse: Decodable {
        let servers: [ServerEntry]
    }

    private struct ServerEntry: Decodable {
        let handle: String
        let live: Bool
    }

    /// The server's origin plus the probe's path. The pairing's server URL is
    /// validated as `https://<label>.getbb.app` when it is redeemed; taking
    /// only its origin means nothing else in it can move the request.
    private static func serversURL(_ serverURL: URL) -> URL? {
        guard let source = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        var components = URLComponents()
        components.scheme = source.scheme
        components.host = source.host
        components.port = source.port
        components.path = path
        return components.url
    }
}

/// `text` with every occurrence of `credential` replaced. Failure text built
/// around a request is shown to the user, and the credential is a password:
/// a transport error that echoes what it sent must not carry it into a row.
func scrubbing(_ credential: String, from text: String) -> String {
    guard !credential.isEmpty else { return text }
    return text.replacingOccurrences(of: credential, with: Pairing.redacted)
}
