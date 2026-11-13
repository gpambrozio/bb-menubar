import Foundation

/// Why pairing did not happen. The first four are about what was pasted; the
/// rest are getbb.app's answer, named as bb 0.49.0's own client names them
/// (`codeForStatus` in `packages/connect-client/src/redeem-machine.ts`), in
/// the words of the design's pairing table.
///
/// No message carries the redeem answer's body: on success it holds the
/// credential, and a refused success is still a success on the wire.
public enum ConnectPairingError: MessageError, Equatable, Sendable {
    case emptyInput
    /// JSON that has no usable `code`.
    case missingCode
    /// Starts like JSON but does not read as bb's machine-code payload.
    case unreadableInput
    /// A pasted payload whose `apex` is not getbb.app. The code is never sent
    /// anywhere else, so it is refused rather than redeemed at getbb.app.
    case foreignApex(String)
    case machineLimit
    case alreadyUsed
    case expired
    /// getbb.app failed (HTTP ≥ 500) or never answered; the detail says which.
    case unreachable(String)
    case refused
    /// A 2xx body that is not `{credential, machineId, serverUrl}`, whose
    /// `serverUrl` is not one label under getbb.app, or whose credential or
    /// machine id is not a header-safe token (see `Pairing`).
    case unreadableAnswer

    public var message: String {
        switch self {
        case .emptyInput: "Enter a machine code."
        case .missingCode: "That has no machine code in it."
        case .unreadableInput: "That is neither a machine code nor bb's machine-code JSON."
        case .foreignApex(let apex): "That code is for \(apex); bb Icon pairs only through \(ConnectPairing.apex)."
        case .machineLimit:
            "Your bb Connect account has no free machine slots. Revoke a device you no longer use at getbb.app/dashboard, then try again."
        case .alreadyUsed: "That code was already used. Make a new one."
        case .expired: "That code has expired — codes last 10 minutes. Make a new one."
        case .unreachable(let detail): "getbb.app could not be reached: \(detail)"
        case .refused: "getbb.app did not accept that code."
        case .unreadableAnswer:
            "getbb.app answered in a way bb Icon cannot read. It may have paired anyway: "
                + "if a new device is listed at getbb.app/dashboard, remove it there."
        }
    }
}

/// Turning a one-time machine code into bb Icon's own pairing with a remote
/// bb, as bb's mobile app does: `POST https://getbb.app/api/connect/redeem-machine`
/// with `{"code": …}`, answered by `{credential, machineId, serverUrl}`.
public enum ConnectPairing {
    /// bb Connect's only production apex. Fixed: a pasted payload naming
    /// another is refused, and a redeemed server must live under it.
    public static let apex = "https://getbb.app"
    static let apexHost = "getbb.app"
    static let redeemPath = "/api/connect/redeem-machine"

    /// The code in what the user pasted: a bare code, or the JSON that bb's
    /// QR code and `bb connect machine-code --json` carry
    /// (`{code, serverUrl, apex, expiresAt}`), of which only `code` and
    /// `apex` are read.
    public static func parseInput(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectPairingError.emptyInput }
        guard trimmed.hasPrefix("{") else { return trimmed }
        let payload: MachineCodePayload
        do {
            payload = try JSONDecoder().decode(MachineCodePayload.self, from: Data(trimmed.utf8))
        } catch {
            throw ConnectPairingError.unreadableInput
        }
        if let apex = payload.apex, apex != Self.apex, apex != Self.apex + "/" {
            throw ConnectPairingError.foreignApex(apex)
        }
        let code = payload.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !code.isEmpty else { throw ConnectPairingError.missingCode }
        return code
    }

    /// The longest `deviceName` getbb.app accepts. Its redeem route
    /// (`apps/web/src/routes/api.connect.redeem-machine.tsx` on get-bb/bb
    /// `main`, from get-bb/bb#7195) validates the field as
    /// `z.string().trim().min(1).max(128).optional()`, and refuses the whole
    /// request, code unspent, as `invalid-request` when it does not fit. zod
    /// counts JavaScript string length: UTF-16 code units.
    static let maxDeviceNameLength = 128

    /// What `deviceName` carries for a Mac named `name`: the name trimmed,
    /// then cut to `maxDeviceNameLength` UTF-16 code units at a character
    /// boundary, as bb's desktop app trims and slices its hostname. Nil when
    /// nothing is left, so the field is omitted rather than refused.
    static func deviceName(from name: String?) -> String? {
        // JavaScript's `trim` also strips U+FEFF, which Foundation's set lacks.
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        var kept = ""
        var units = 0
        for character in (name ?? "").trimmingCharacters(in: blank) {
            units += character.utf16.count
            guard units <= maxDeviceNameLength else { break }
            kept.append(character)
        }
        let trimmed = kept.trimmingCharacters(in: blank)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Redeems `code` at getbb.app. The request carries the code, this Mac's
    /// name as `deviceName` (see `deviceName(from:)`), and a content type,
    /// nothing else: no credential exists yet, and bb Icon sends no `Origin`.
    /// The name is what getbb.app/dashboard lists the device as; without it
    /// the row has nothing to tell it apart.
    ///
    /// No `kind` is sent, though the route takes one (`desktop`, `mobile`,
    /// `host`): getbb.app revokes a pairing that has a kind and is not used
    /// within 14 days of pairing (`isAbandonedPairing` in
    /// `apps/web/src/server/api.ts`), and bb Icon's pairing sits unused for
    /// as long as this Mac's own bb is running. A pairing without a kind is
    /// never revoked automatically.
    ///
    /// A non-2xx answer is classified by its status and, when the body is
    /// `{error}`, its wire error. bb's client reads the body as JSON first
    /// and calls any non-JSON body unreadable; here a non-JSON refusal is
    /// still classified by status, so a proxy's HTML 502 reads as getbb.app
    /// being unreachable rather than as a bad answer.
    public static func redeem(code: String, deviceName name: String?, http: any HTTPClient) async throws -> Pairing {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ConnectPairingError.emptyInput }
        var components = URLComponents()
        components.scheme = "https"
        components.host = apexHost
        components.path = redeemPath
        guard let url = components.url else { throw ConnectPairingError.unreachable("no redeem URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(RedeemRequest(code: code, deviceName: deviceName(from: name)))

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            throw ConnectPairingError.unreachable(errorText(error))
        }
        guard (200..<300).contains(response.statusCode) else {
            let wireError = (try? JSONDecoder().decode(WireError.self, from: data))?.error ?? ""
            throw refusal(status: response.statusCode, wireError: wireError)
        }
        // The decoding error's detail is dropped on purpose: the design names
        // this case in one sentence, and the body it describes holds the
        // credential.
        guard let answer = try? JSONDecoder().decode(RedeemAnswer.self, from: data),
              let serverUrl = answer.serverUrl,
              let handle = handle(forServerURL: serverUrl),
              let serverURL = URL(string: "https://\(handle).\(apexHost)"),
              let pairing = try? Pairing(
                  serverURL: serverURL, handle: handle, machineId: answer.machineId, credential: answer.credential
              )
        else { throw ConnectPairingError.unreadableAnswer }
        return pairing
    }

    /// bb 0.49.0's `codeForStatus`, in the same order.
    static func refusal(status: Int, wireError: String) -> ConnectPairingError {
        if wireError == "machine-limit" { return .machineLimit }
        if wireError == "already-used" || status == 409 { return .alreadyUsed }
        if wireError == "expired" || status == 410 { return .expired }
        if status >= 500 { return .unreachable("HTTP \(status)") }
        return .refused
    }

    /// The label of `https://<label>.getbb.app`, or nil for anything else:
    /// another scheme or host, a port, credentials, a path, a query, or a
    /// label that is not one DNS label. Stricter than bb's `handleForApex`,
    /// which checks scheme, port, and host only; the stored URL is rebuilt
    /// from the label, so nothing else from the answer is kept anyway.
    static func handle(forServerURL string: String) -> String? {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let host = components.host?.lowercased()
        else { return nil }
        let suffix = "." + apexHost
        guard host.hasSuffix(suffix) else { return nil }
        let label = host.dropLast(suffix.count)
        guard (1...63).contains(label.count),
              label.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }),
              label.first != "-",
              label.last != "-"
        else { return nil }
        return String(label)
    }

    private struct MachineCodePayload: Decodable {
        let code: String?
        let apex: String?
    }

    /// Exactly the fields sent. A nil `deviceName` is left out of the JSON
    /// (synthesized `Encodable` uses `encodeIfPresent`), never sent as null,
    /// which the route's `optional()` would refuse. There is no `kind` here
    /// on purpose; see `redeem`.
    private struct RedeemRequest: Encodable {
        let code: String
        let deviceName: String?
    }

    private struct RedeemAnswer: Decodable {
        let credential: String
        let machineId: String
        let serverUrl: String?
    }

    private struct WireError: Decodable {
        let error: String
    }
}
