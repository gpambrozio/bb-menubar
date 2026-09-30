import Foundation
import Testing
@testable import BBIconCore

/// Against the bb this Mac is running, found through its runtime file.
/// Opt-in, because it needs bb running and reads the user's real threads:
///
///     BB_ICON_LIVE=1 swift test --package-path BBIconPackage --filter LiveBBTests
///
/// It never calls `openThread`: that would navigate the user's bb window.
struct LiveBBTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["BB_ICON_LIVE"] == "1" }

    @Test("the running bb's snapshot decodes whole", .enabled(if: enabled))
    func liveSnapshotDecodes() async throws {
        let runtimeFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".bb/bb-app-runtime.json")
        // TODO(Task 7): use RuntimeFile.parse
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: runtimeFile)) as? [String: Any]
        let serverURL = try #require((object?["serverUrl"] as? String).flatMap { URL(string: $0) })
        let snapshot = try await BBAPI(serverURL: serverURL, http: URLSessionHTTPClient()).fetchSnapshot()
        #expect(snapshot.decodeFailures.isEmpty)
        #expect(!snapshot.truncated)
    }
}
