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
public struct Pairing: Codable, Equatable, Sendable {
    /// `https://<handle>.getbb.app`, the server's address through the relay.
    public let serverURL: URL
    /// The server's DNS label under getbb.app, which names it in the menu.
    public let handle: String
    /// This device's id in the getbb.app dashboard; what revoke names.
    public let machineId: String
    public let credential: String

    public init(serverURL: URL, handle: String, machineId: String, credential: String) {
        self.serverURL = serverURL
        self.handle = handle
        self.machineId = machineId
        self.credential = credential
    }

    static let redacted = "<redacted>"
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
