import Foundation
import Testing
@testable import BBIconCore

struct ResourceBundleLocatorTests {
    static let name = "BBIconPackage_BBIcon.bundle"
    static let app = URL(fileURLWithPath: "/Applications/BBIcon.app", isDirectory: true)
    static let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    static let executable = app.appendingPathComponent("Contents/MacOS/BBIcon")

    /// Locates with the three candidates of a packaged app, `existing` being
    /// the paths that exist. Returns the answer and every path asked about.
    static func locate(existing: Set<String>, resourceURL: URL? = resources) -> (URL?, [String]) {
        var asked: [String] = []
        let found = ResourceBundleLocator.locate(
            bundleName: name,
            resourceURL: resourceURL,
            bundleURL: app,
            executableURL: executable
        ) { url in
            asked.append(url.path)
            return existing.contains(url.path)
        }
        return (found, asked)
    }

    static let inResources = "/Applications/BBIcon.app/Contents/Resources/BBIconPackage_BBIcon.bundle"
    static let inApp = "/Applications/BBIcon.app/BBIconPackage_BBIcon.bundle"
    static let besideExecutable = "/Applications/BBIcon.app/Contents/MacOS/BBIconPackage_BBIcon.bundle"

    @Test("a packaged app's Resources comes first, where npm run dist puts the bundle")
    func resourcesFirst() {
        let (found, asked) = Self.locate(existing: [Self.inResources, Self.inApp, Self.besideExecutable])
        #expect(found?.path == Self.inResources)
        #expect(asked == [Self.inResources])
    }

    @Test("then the bundle's own directory, then the executable's, in that order")
    func fallsThroughInOrder() {
        let (inApp, _) = Self.locate(existing: [Self.inApp, Self.besideExecutable])
        #expect(inApp?.path == Self.inApp)
        let (beside, asked) = Self.locate(existing: [Self.besideExecutable])
        #expect(beside?.path == Self.besideExecutable)
        #expect(asked == [Self.inResources, Self.inApp, Self.besideExecutable])
    }

    @Test("a missing resource URL is skipped, not a trap")
    func nilCandidateSkipped() {
        let (found, asked) = Self.locate(existing: [Self.inApp], resourceURL: nil)
        #expect(found?.path == Self.inApp)
        #expect(asked == [Self.inApp])
    }

    @Test("nil when the bundle is nowhere, so the caller can name it")
    func noneFound() {
        let (found, asked) = Self.locate(existing: [])
        #expect(found == nil)
        #expect(asked.count == 3)
    }
}
