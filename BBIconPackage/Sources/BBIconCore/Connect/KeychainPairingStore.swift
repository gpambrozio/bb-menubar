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
    /// An item exists but is not a pairing this version can read.
    case unreadable
    /// The pairing could not be encoded to be stored.
    case unencodable

    public var message: String {
        switch self {
        case .status(let status, let operation):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "bb Icon could not \(operation.rawValue) its bb Connect pairing in the Keychain: \(text) (OSStatus \(status))"
        case .unreadable:
            return "bb Icon's bb Connect pairing in the Keychain cannot be read. Forget it and pair again."
        case .unencodable:
            return "bb Icon could not prepare its bb Connect pairing for the Keychain."
        }
    }
}

/// The pairing as one generic-password item: the JSON-encoded `Pairing` as
/// its data, accessible after first unlock and never synced or migrated to
/// another device.
///
/// This is the login (file-based) keychain, not the data protection
/// keychain: the latter needs a keychain-access-groups entitlement, which an
/// unsigned build does not have.
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

    /// Adds the item, or replaces the data of the one already there, so a
    /// failure part-way never leaves the Mac without its earlier pairing.
    public func save(_ pairing: Pairing) throws {
        guard let data = try? JSONEncoder().encode(pairing) else {
            throw KeychainPairingStoreError.unencodable
        }
        var add = itemQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "bb Icon bb Connect pairing"
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data] as CFDictionary
            let updated = SecItemUpdate(itemQuery as CFDictionary, update)
            guard updated == errSecSuccess else {
                throw KeychainPairingStoreError.status(updated, operation: .save)
            }
        default:
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
