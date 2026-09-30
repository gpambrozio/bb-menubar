import Foundation
import Testing
@testable import BBIconCore

/// Against the remote bb this Mac is paired with, through the getbb.app
/// relay, using the pairing the app stored in the Keychain. Opt-in, because it
/// needs a real pairing, reads the user's real threads, and may raise a
/// Keychain prompt. Answer it with **Allow**, not Always Allow: that would add
/// the test runner to the item's access list for good.
///
///     BB_ICON_LIVE_REMOTE=1 swift test --package-path BBIconPackage --filter LiveRemoteTests
///
/// It only reads the stored item, never writes or deletes it, and never calls
/// `openThread`: that would navigate every bb window on every client of the
/// server. Nothing here prints the pairing, and no expectation mentions it,
/// so a failure cannot quote the credential.
struct LiveRemoteTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["BB_ICON_LIVE_REMOTE"] == "1" }

    @Test("the paired remote bb's snapshot decodes whole through the relay", .enabled(if: enabled))
    func liveRemoteSnapshotDecodes() async throws {
        guard let pairing = try KeychainPairingStore().load() else {
            Issue.record("No bb Connect pairing is stored. Pair from the menu first.")
            return
        }
        let api = BBAPI(
            serverURL: pairing.serverURL,
            headers: [ConnectHealth.credentialHeader: pairing.credential],
            http: URLSessionHTTPClient()
        )
        let snapshot = try await api.fetchSnapshot()
        #expect(snapshot.decodeFailures.isEmpty)
        #expect(!snapshot.truncated)
    }
}
