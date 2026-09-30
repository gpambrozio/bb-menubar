import Foundation
import Testing
@testable import BBIconCore

/// The only file in the runtime stack that talks to a C API. Every other
/// watcher test injects a fake `open`, so without this nothing exercises the
/// real callback at all. Ported from paseo-menubar, where the first version
/// of that callback crashed on its first event. These use the real file
/// system and FSEvents' real latency, so they wait in real time.
@MainActor
struct FSEventsWatchTests {
    /// Longer than the stream's one-second latency, so an event that was
    /// going to be delivered has been.
    static let deliveryWindow: Duration = .milliseconds(1_500)

    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("delivers a change for the runtime file, and not for bb's database")
    func deliversRelevantChanges() async throws {
        let dir = try Self.temporaryDirectory("fsevents")
        defer { try? FileManager.default.removeItem(at: dir) }
        var changes = 0
        var errors = 0
        let stop = try FSEventsWatch.open(
            directory: dir.path,
            include: RuntimeFile.isRuntimeFileEvent,
            onChange: { changes += 1 },
            onError: { errors += 1 }
        )
        defer { stop() }

        // bb's database lives in the same directory and is written constantly.
        try Data("x".utf8).write(to: dir.appendingPathComponent("bb.db-wal"))
        // Give the stream a chance to deliver the irrelevant event before the
        // relevant one, so a pass cannot come from the two being coalesced.
        try await Task.sleep(for: Self.deliveryWindow)
        let beforeRelevant = changes

        // The filter is the whole job of `handle`. Without this assertion the
        // test passes with the filter removed entirely.
        #expect(beforeRelevant == 0, "an event for a file the session ignores must not trigger a re-read")

        try Data("{}".utf8).write(to: dir.appendingPathComponent(RuntimeFile.fileName))
        #expect(await eventually { changes > beforeRelevant })
        #expect(errors == 0)
    }

    @Test("reports the watch as dead when its directory is replaced")
    func reportsRootChange() async throws {
        let parent = try Self.temporaryDirectory("fsevents-root")
        defer { try? FileManager.default.removeItem(at: parent) }
        let watched = parent.appendingPathComponent(".bb", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        var errors = 0
        let stop = try FSEventsWatch.open(
            directory: watched.path,
            include: RuntimeFile.isRuntimeFileEvent,
            onChange: {},
            onError: { errors += 1 }
        )
        defer { stop() }

        // The watcher has to hear about this, or the tray sits on the poll
        // for the life of the process.
        try FileManager.default.removeItem(at: watched)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        #expect(await eventually { errors > 0 })
    }

    @Test("stopping twice is safe, and stops delivering")
    func stopIsIdempotent() async throws {
        let dir = try Self.temporaryDirectory("fsevents-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        var changes = 0
        var errors = 0
        let stop = try FSEventsWatch.open(
            directory: dir.path,
            include: RuntimeFile.isRuntimeFileEvent,
            onChange: { changes += 1 },
            onError: { errors += 1 }
        )
        stop()
        stop()
        try Data("{}".utf8).write(to: dir.appendingPathComponent(RuntimeFile.fileName))
        try await Task.sleep(for: Self.deliveryWindow)
        #expect(changes == 0)
        #expect(errors == 0)
    }
}
