import Foundation
import Security
import Testing
@testable import BBIconCore

/// The store contract, run against the fake and against the real Keychain.
/// Each Keychain test uses its own service name, never the app's, and deletes
/// its item before it returns.
@Suite(.serialized)
struct KeychainPairingStoreTests {
    private static func pairing(_ handle: String) throws -> Pairing {
        Pairing(
            serverURL: try #require(URL(string: "https://\(handle).getbb.app")),
            handle: handle,
            machineId: "m-\(handle)",
            credential: "cred-test-\(handle)"
        )
    }

    private static func testService() -> String {
        "br.eng.gustavo.bb-menubar.connect.test.\(UUID().uuidString)"
    }

    /// Empty, save, replace, delete, delete again.
    private static func exerciseContract(_ store: any PairingStore) throws {
        #expect(try store.load() == nil)
        let first = try pairing("mini")
        try store.save(first)
        #expect(try store.load() == first)
        let second = try pairing("studio")
        try store.save(second)
        #expect(try store.load() == second)
        try store.delete()
        #expect(try store.load() == nil)
        // Forgetting what is already gone is not an error.
        try store.delete()
    }

    @Test("the fake keeps the store contract")
    func fakeKeepsContract() throws {
        try Self.exerciseContract(FakePairingStore())
    }

    @Test("the Keychain store keeps the store contract")
    func keychainKeepsContract() throws {
        let store = KeychainPairingStore(service: Self.testService())
        defer { try? store.delete() }
        try Self.exerciseContract(store)
    }

    @Test("the stored item is one generic password under the fixed account")
    func keychainItemAttributes() throws {
        let service = Self.testService()
        let store = KeychainPairingStore(service: service)
        defer { try? store.delete() }
        try store.save(Self.pairing("mini"))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrAccount as String] as? String == KeychainPairingStore.account)
        // The login keychain does not report `kSecAttrAccessible` back (it
        // reads as nil), so the accessibility the store asks for is checked
        // by review, not here.
    }

    @Test("an item that does not decode is named without its contents")
    func keychainUnreadableItem() throws {
        let service = Self.testService()
        let store = KeychainPairingStore(service: service)
        defer { try? store.delete() }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainPairingStore.account,
            kSecValueData as String: Data(#"{"credential":"cred-test-garbled""#.utf8),
        ]
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(throws: KeychainPairingStoreError.unreadable) { try store.load() }
    }

    @Test("a Keychain failure names its status, and nothing else")
    func statusMessage() {
        let message = KeychainPairingStoreError.status(errSecAuthFailed, operation: .save).message
        #expect(message.hasPrefix("bb Icon could not save its bb Connect pairing in the Keychain: "))
        #expect(message.hasSuffix("(OSStatus -25293)"))
    }
}
