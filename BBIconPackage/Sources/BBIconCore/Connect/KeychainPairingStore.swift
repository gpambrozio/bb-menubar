import Foundation
import Security

/// Why the Keychain did not keep or give back the pairing. Messages name the
/// `OSStatus` and never the item's data, which holds the credential.
public enum KeychainPairingStoreError: MessageError, Equatable, Sendable {
    public enum Operation: String, Sendable {
        case load = "read"
        case save
        case delete = "remove"
    }

    case status(OSStatus, operation: Operation)
    /// An item exists but is not a pairing this version can read. It is
    /// only ever met at load, when there is no pairing in memory and the menu
    /// offers **Connect to a remote bb…** rather than Forget; pairing again
    /// saves over the item.
    case unreadable
    /// The pairing could not be encoded to be stored.
    case unencodable

    public var message: String {
        switch self {
        case .status(let status, let operation):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "bb Icon could not \(operation.rawValue) its bb Connect pairing in the Keychain: \(text) (OSStatus \(status))"
        case .unreadable:
            return "bb Icon's bb Connect pairing in the Keychain cannot be read. Connect to a remote bb again to replace it."
        case .unencodable:
            return "bb Icon could not prepare its bb Connect pairing for the Keychain."
        }
    }
}

/// The pairing as one generic-password item, the JSON-encoded `Pairing` as
/// its data, in the login (file-based) keychain.
///
/// Not the data protection keychain: that needs a keychain-access-groups
/// entitlement, which an unsigned build does not have. The file-based
/// keychain ignores `kSecAttrAccessible`, so the item is **not** limited to
/// this device: it is never synced, but Migration Assistant carries it to a
/// new Mac. `AfterFirstUnlockThisDeviceOnly` is still requested, for the day
/// this moves to the data protection keychain; nothing here enforces it.
///
/// A loaded item is decoded through `Pairing`'s validating decoder, so an
/// item naming a server outside getbb.app reads as `.unreadable`.
public struct KeychainPairingStore: PairingStore {
    public static let defaultService = "br.eng.gustavo.bb-menubar.connect"
    /// One pairing per Mac, so one fixed account under the service.
    static let account = "pairing"

    private let service: String

    public init(service: String = KeychainPairingStore.defaultService) {
        self.service = service
    }

    public func load() throws -> Pairing? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return nil
        default: throw KeychainPairingStoreError.status(status, operation: .load)
        }
        // The decoder's own error is dropped: it can quote the data.
        guard let data = result as? Data,
              let pairing = try? JSONDecoder().decode(Pairing.self, from: data)
        else { throw KeychainPairingStoreError.unreadable }
        return pairing
    }

    /// Adds the item. If one is already there it is deleted and the add
    /// retried, never updated in place: an update keeps the existing item's
    /// access list, and an item bb Icon did not create may let another
    /// program read the credential. The cost is that a failed second add
    /// leaves no pairing at all, which the thrown error names.
    public func save(_ pairing: Pairing) throws {
        guard let data = try? JSONEncoder().encode(pairing) else {
            throw KeychainPairingStoreError.unencodable
        }
        var add = itemQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "bb Icon bb Connect pairing"
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try delete()
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainPairingStoreError.status(status, operation: .save)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairingStoreError.status(status, operation: .delete)
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
