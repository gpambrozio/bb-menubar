import Foundation

/// The best-effort revoke **Forget** makes before it deletes the pairing.
/// bb 0.44.0's own `revokeMachine` (the connect builtin plugin) is the
/// reference: `POST https://getbb.app/api/connect/revoke-machine` with the
/// machine header and `{"machineId": …}`, answered by `{ok: true}`.
///
/// Whether the relay lets a device revoke itself is not visible in bb's code,
/// so every failure points to the dashboard, where the device can be removed
/// by hand.
public enum ConnectRevoke {
    static let path = "/api/connect/revoke-machine"

    /// Asks getbb.app to revoke this device. `nil` when it did; otherwise a
    /// sentence naming the failure and where to remove the device by hand.
    /// Never throws: the caller deletes the pairing whatever this answers.
    public static func revoke(pairing: Pairing, http: any HTTPClient) async -> String? {
        let failure = "Could not revoke bb Icon's pairing with \(pairing.handle); "
            + "remove the device by hand at getbb.app/dashboard."
        var components = URLComponents()
        components.scheme = "https"
        components.host = ConnectPairing.apexHost
        components.path = path
        guard let url = components.url,
              let body = try? JSONEncoder().encode(["machineId": pairing.machineId])
        else {
            return "\(failure) bb Icon could not build the request."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pairing.credential, forHTTPHeaderField: ConnectHealth.credentialHeader)
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            return "\(failure) getbb.app could not be reached: \(scrubbing(pairing.credential, from: errorText(error)))"
        }
        switch response.statusCode {
        case 200..<300: break
        case 500...: return "\(failure) getbb.app could not be reached: HTTP \(response.statusCode)"
        default: return "\(failure) getbb.app refused it (HTTP \(response.statusCode))."
        }
        guard (try? JSONDecoder().decode(RevokeResult.self, from: data))?.ok == true else {
            return "\(failure) getbb.app answered in a way bb Icon cannot read."
        }
        return nil
    }

    private struct RevokeResult: Decodable {
        let ok: Bool
    }
}
