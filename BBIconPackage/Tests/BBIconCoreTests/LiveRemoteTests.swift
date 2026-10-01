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

    /// The relay refuses the machine header on a WebSocket upgrade; this is
    /// the path the tray takes instead: a desktop session minted just before
    /// the dial, sent as a cookie. A failure's text is the transport's, which
    /// never carries a header value.
    @Test("the paired remote bb's /ws opens with a freshly minted session", .enabled(if: enabled))
    @MainActor
    func liveRemoteSocketOpens() async throws {
        guard let pairing = try KeychainPairingStore().load() else {
            Issue.record("No bb Connect pairing is stored. Pair from the menu first.")
            return
        }
        let http = URLSessionHTTPClient()
        let session: [String: String]
        do throws(ConnectSessionError) {
            session = try await ConnectSession.dialHeaders(pairing: pairing, http: http)
        } catch {
            Issue.record("\(error.message)")
            return
        }
        let headers = [ConnectHealth.credentialHeader: pairing.credential].merging(session) { _, minted in minted }
        let transport = URLSessionWebSocketTransport(
            request: TransportRequest(url: RealtimeSession.websocketURL(for: pairing.serverURL), headers: headers)
        )
        var opened = false
        var failure: String?
        transport.onOpen = { opened = true }
        transport.onError = { if failure == nil { failure = $0 } }
        transport.connect()
        defer { transport.close(code: 1000, reason: "live test") }
        await eventually(timeout: .seconds(20)) { opened || failure != nil }
        #expect(opened, "\(failure ?? "no answer in 20 s")")
    }
}
