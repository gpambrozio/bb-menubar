import Foundation
import Testing
@testable import BBIconCore

/// Ported from paseo-menubar's `RegistryWatcherTests`, minus the file filter,
/// which moved to the injected `include` (`RuntimeFile.isRuntimeFileEvent`).
@MainActor
struct DirectoryWatcherTests {
    struct NotThere: Error {}

    @MainActor
    final class OpenCall {
        let dir: String
        let fire: () -> Void
        let fail: () -> Void
        var closed = false

        init(dir: String, fire: @escaping () -> Void, fail: @escaping () -> Void) {
            self.dir = dir
            self.fire = fire
            self.fail = fail
        }
    }

    @MainActor
    final class Harness {
        private(set) var opens: [OpenCall] = []
        private(set) var probes = 0
        /// Probes that have returned or thrown.
        private(set) var resolved = 0
        var changes = 0
        /// Built after the stored properties so the callbacks can capture self.
        private(set) var watcher: DirectoryWatcher?

        init(resolveDir: @escaping () async throws -> String, openThrows: ((Int) -> Bool)? = nil) {
            watcher = DirectoryWatcher(
                resolveDir: { [weak self] in
                    self?.probes += 1
                    defer { self?.resolved += 1 }
                    return try await resolveDir()
                },
                open: { [weak self] dir, onChange, onError in
                    guard let self else { return {} }
                    let attempt = self.opens.count + 1
                    if openThrows?(attempt) == true {
                        // The directory vanished between resolution and the call.
                        self.opens.append(OpenCall(dir: dir, fire: {}, fail: {}))
                        throw FSEventsWatchError.couldNotStart(dir)
                    }
                    let call = OpenCall(dir: dir, fire: onChange, fail: onError)
                    self.opens.append(call)
                    return { call.closed = true }
                }
            )
        }

        func watch(_ onChange: @escaping () -> Void = {}) throws -> () -> Void {
            try #require(watcher).watch(onChange)
        }

        func ensureAttached() throws {
            try #require(watcher).ensureAttached()
        }
    }

    @Test("attaches to the resolved directory and forwards changes")
    func attaches() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        _ = try h.watch { h.changes += 1 }
        await settle(until: { h.opens.count == 1 })

        #expect(h.opens.count == 1)
        #expect(h.opens.first?.dir == "/home/.bb")
        h.opens.first?.fire()
        #expect(h.changes == 1)
    }

    @Test("attaches on a later read when the directory did not exist at launch")
    func attachesLater() async throws {
        var exists = false
        let h = Harness(resolveDir: {
            if !exists { throw NotThere() }
            return "/home/.bb"
        })

        _ = try h.watch()
        await settle()
        #expect(h.opens.isEmpty)

        // bb creating ~/.bb mid-session must not leave the tray on the poll
        // for the life of the process.
        exists = true
        try h.ensureAttached()
        await settle(until: { h.opens.count == 1 })
        #expect(h.opens.count == 1)
    }

    @Test("never throws when the directory cannot be resolved")
    func resolveFailure() async throws {
        let h = Harness(resolveDir: { throw NotThere() })
        // An unhandled error here would be fatal in the app.
        _ = try h.watch()
        await settle()
        #expect(h.opens.isEmpty)
    }

    @Test("does not open a second watch while one is already attached")
    func singleWatch() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        _ = try h.watch()
        await settle(until: { h.opens.count == 1 })
        try h.ensureAttached()
        try h.ensureAttached()
        await settle()

        #expect(h.opens.count == 1)
    }

    @Test("does not probe the directory again while a probe is in flight")
    func singleProbe() async throws {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/home/.bb"
        })

        _ = try h.watch()
        await settle(until: { h.probes == 1 })
        try h.ensureAttached()
        try h.ensureAttached()
        await settle()

        // `ensureAttached` runs after every read, so without this guard a slow
        // probe would stack one more on each poll.
        #expect(h.probes == 1)
        gate.open()
        await eventually { h.opens.count == 1 }
        #expect(h.opens.count == 1)
    }

    @Test("re-attaches after the watch reports an error")
    func reattaches() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        _ = try h.watch()
        await settle(until: { h.opens.count == 1 })

        // FSEvents reports the watched directory being replaced as the watch
        // dying. Without a fresh attach the tray is on the poll alone.
        h.opens.first?.fail()
        try h.ensureAttached()
        await settle(until: { h.opens.count == 2 })

        #expect(h.opens.count == 2)
    }

    @Test("a watch that dies is reported as a change, so the re-read and re-attach happen now")
    func deathNotifies() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        _ = try h.watch { h.changes += 1 }
        await settle(until: { h.opens.count == 1 })

        h.opens.first?.fail()
        #expect(h.changes == 1)

        // What the session's read does on its way out.
        try h.ensureAttached()
        await settle(until: { h.opens.count == 2 })
        #expect(h.opens.count == 2)
    }

    @Test("a watch that dies after detach reports nothing")
    func deathAfterDetachIsSilent() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        let stop = try h.watch { h.changes += 1 }
        await settle(until: { h.opens.count == 1 })
        stop()
        h.opens.first?.fail()
        #expect(h.changes == 0)
    }

    @Test("stops watching and stops forwarding once detached")
    func detaches() async throws {
        let h = Harness(resolveDir: { "/home/.bb" })
        let stop = try h.watch { h.changes += 1 }
        await settle(until: { h.opens.count == 1 })

        stop()
        #expect(h.opens.first?.closed == true)
        h.opens.first?.fire()
        #expect(h.changes == 0)

        // And a read arriving after shutdown must not resurrect it.
        try h.ensureAttached()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("stays detached, and tries again later, when open itself throws")
    func openThrows() async throws {
        let h = Harness(resolveDir: { "/home/.bb" }, openThrows: { $0 == 1 })
        _ = try h.watch()
        await settle(until: { h.opens.count == 1 })
        #expect(h.opens.count == 1)

        // A throw must not count as attached, or the tray sits on the poll for
        // the life of the process with a watch it never had.
        try h.ensureAttached()
        await settle(until: { h.opens.count == 2 })
        #expect(h.opens.count == 2)
    }

    @Test("does not attach a directory that resolves after the watcher was detached")
    func resolvesAfterDetach() async throws {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/home/.bb"
        })

        let stop = try h.watch()
        await settle(until: { h.probes == 1 })
        stop()
        gate.open()
        // The gate resumes the probe from another thread. Once it has
        // returned, the watcher runs to its decision without suspending.
        await eventually { h.resolved == 1 }
        await settle()

        #expect(h.opens.isEmpty)
    }
}
