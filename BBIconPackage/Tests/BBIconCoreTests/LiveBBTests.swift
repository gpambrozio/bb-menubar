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
        let runtimeFile = URL(fileURLWithPath: RuntimeFile.directory(home: NSHomeDirectory()))
            .appending(path: RuntimeFile.fileName)
        let info = try RuntimeFile.parse(Data(contentsOf: runtimeFile))
        let snapshot = try await BBAPI(serverURL: info.serverURL, http: URLSessionHTTPClient()).fetchSnapshot()
        #expect(snapshot.decodeFailures.isEmpty)
        #expect(!snapshot.truncated)
    }
}
