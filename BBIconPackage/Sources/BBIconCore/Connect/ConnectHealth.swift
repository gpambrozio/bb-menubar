import Foundation

/// What the bb Connect relay says about the paired server, asked when a fetch
/// or the socket to it fails. A remote connection can fail in ways a loopback
/// one cannot, and each is named rather than shown as the raw failure.
public enum ConnectHealthFinding: Equatable, Sendable {
    /// The relay refused the machine credential (401/403).
    case revoked
    /// The account's server list has this server not live, or not at all.
    case offline
    /// No answer, a 5xx, or another non-2xx that bb's own client treats as
    /// a network failure. The detail never carries the credential.
    case unreachable(String)
    /// The server is live, so the original failure is the one to show.
    case live
    /// A 2xx whose body is not `{servers: [...]}`, or whose row for this
    /// server has no boolean `live`, naming the field.
    case unreadable(String)

    /// The error row for this finding, from the design's "Naming what goes
    /// wrong" table. `.live` has none: the original error stands.
    public func message(handle: String) -> String? {
        switch self {
        case .revoked:
            Self.revokedMessage(handle: handle)
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

    /// `.revoked`'s row. Also what a refused desktop session says
    /// (`ConnectSession`), since the relay refuses it for the same reason.
    public static func revokedMessage(handle: String) -> String {
        "bb Connect no longer accepts bb Icon's pairing with \(handle). Pair again, or forget it."
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
        case 500...: return .unreachable("HTTP \(response.statusCode)")
        default: return .unreachable("getbb.app answered HTTP \(response.statusCode)")
        }

        let servers: [ServerRow]
        do {
            servers = try JSONDecoder().decode(ServersResponse.self, from: data).servers
        } catch {
            return .unreadable(scrubbing(pairing.credential, from: failureText(error, below: 0)))
        }
        // Handles are DNS labels, which compare without case.
        let handle = pairing.handle.lowercased()
        guard let row = servers.first(where: { $0.handle?.lowercased() == handle }) else { return .offline }
        switch row.live {
        case .success(let live): return live ? .live : .offline
        case .failure(let failure): return .unreadable(scrubbing(pairing.credential, from: failure.reason))
        }
    }

    /// bb's client rejects the whole list over one bad entry. Here only this
    /// server's row decides: a row for another server that is malformed, or
    /// not an object, is ignored rather than hiding this server's state.
    private struct ServersResponse: Decodable {
        let servers: [ServerRow]
    }

    /// One list entry, decoded without throwing so a bad row cannot fail the
    /// list. A row whose `handle` is missing or not a string names no server,
    /// so it can never be this one; `live` keeps its failure, named by field,
    /// in case this is the row that decides.
    private struct ServerRow: Decodable {
        let handle: String?
        let live: Result<Bool, RowFailure>

        struct RowFailure: Error {
            let reason: String
        }

        private enum CodingKeys: String, CodingKey {
            case handle, live
        }

        init(from decoder: any Decoder) {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                handle = nil
                live = .failure(RowFailure(reason: "not an object"))
                return
            }
            handle = try? container.decode(String.self, forKey: .handle)
            do {
                live = .success(try container.decode(Bool.self, forKey: .live))
            } catch {
                live = .failure(RowFailure(reason: failureText(error, below: 0)))
            }
        }
    }

    static func serversURL(_ serverURL: URL) -> URL? {
        relayURL(serverURL, path: path)
    }

    /// The server's origin plus `path`, for the relay's own endpoints.
    /// `Pairing` already refuses a server URL that is not
    /// `https://<label>.getbb.app`; taking only the origin here means nothing
    /// else in one could move the request.
    static func relayURL(_ serverURL: URL, path: String) -> URL? {
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
