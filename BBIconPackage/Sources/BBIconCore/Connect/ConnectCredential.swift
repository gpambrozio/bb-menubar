import Foundation

/// bb Icon's own pairing with one remote bb, as redeemed from a machine code.
///
/// `credential` is a password: it is what the getbb.app relay accepts, in the
/// `x-bb-connect-machine` header, in front of a server whose API runs
/// commands. It lives only here in memory and in the Keychain item. Every
/// rendering of a pairing — `description`, `debugDescription`, `dump`, a
/// `Mirror` — shows the other fields and redacts it, so a pairing that ends
/// up in a log line, an error, or a test failure does not carry it along.
/// `Codable` is for the Keychain item alone.
///
/// A pairing is valid by construction, whether built or decoded: its server is
/// `https://<handle>.getbb.app`, and its machine id and credential are
/// header-safe tokens. A stored item is never trusted to be what bb Icon
/// wrote, since the credential it holds is sent to whatever server it names.
public struct Pairing: Codable, Equatable, Sendable {
    /// `https://<handle>.getbb.app`, the server's address through the relay.
    public let serverURL: URL
    /// The server's DNS label under getbb.app, which names it in the menu.
    public let handle: String
    /// This device's id in the getbb.app dashboard; what revoke names.
    public let machineId: String
    public let credential: String

    /// The longest machine id or credential accepted. Far above anything
    /// getbb.app mints; it bounds what goes into a request header.
    public static let maxTokenLength = 4096

    public init(serverURL: URL, handle: String, machineId: String, credential: String) throws(PairingValidationError) {
        guard ConnectPairing.handle(forServerURL: serverURL.absoluteString) == handle else { throw .serverURL }
        guard Self.isHeaderToken(machineId) else { throw .machineId }
        guard Self.isHeaderToken(credential) else { throw .credential }
        self.serverURL = serverURL
        self.handle = handle
        self.machineId = machineId
        self.credential = credential
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                serverURL: container.decode(URL.self, forKey: .serverURL),
                handle: container.decode(String.self, forKey: .handle),
                machineId: container.decode(String.self, forKey: .machineId),
                credential: container.decode(String.self, forKey: .credential)
            )
        } catch let error as PairingValidationError {
            // The message names the field, never its value.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    /// One to `maxTokenLength` visible ASCII characters: no space, tab, CR,
    /// LF, or anything outside ASCII, so the value cannot split or corrupt
    /// the header it is sent in.
    static func isHeaderToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...maxTokenLength).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static let redacted = "<redacted>"
}

/// Which field made a pairing invalid. Messages name the field only.
public enum PairingValidationError: MessageError, Equatable, Sendable {
    case serverURL
    case machineId
    case credential

    public var message: String {
        switch self {
        case .serverURL: "A bb Connect pairing's server must be https://<handle>.getbb.app."
        case .machineId: "A bb Connect pairing's machine id must be 1 to 4096 visible ASCII characters."
        case .credential: "A bb Connect pairing's credential must be 1 to 4096 visible ASCII characters."
        }
    }
}

extension Pairing: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "Pairing(serverURL: \(serverURL.absoluteString), handle: \(handle), machineId: \(machineId), credential: \(Self.redacted))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "serverURL": serverURL,
            "handle": handle,
            "machineId": machineId,
            "credential": Self.redacted,
        ], displayStyle: .struct)
    }
}

/// Where the one pairing is kept between launches. Injected, so everything
/// above it is tested without the Keychain.
public protocol PairingStore: Sendable {
    /// The stored pairing, or nil when there is none.
    func load() throws -> Pairing?
    /// Stores `pairing`, replacing any earlier one.
    func save(_ pairing: Pairing) throws
    /// Removes the stored pairing. Removing one that is not there is not an
    /// error.
    func delete() throws
}
