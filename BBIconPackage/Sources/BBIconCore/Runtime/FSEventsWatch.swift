import CoreServices
import Foundation

public enum FSEventsWatchError: MessageError {
    case couldNotStart(String)

    public var message: String {
        switch self {
        case .couldNotStart(let dir): "Could not start watching \(dir)"
        }
    }
}

/// The production watch behind `DirectoryWatcher`: FSEvents on one directory
/// with per-file events, filtered by the caller's `include`. Per-file events
/// are what let the filter see which file changed, so bb rewriting its
/// runtime file wakes the tray and its database's constant writes in the
/// same directory do not. A root change (the directory deleted or replaced)
/// is reported as the watch dying, so the watcher re-attaches on its next
/// read. Ported from paseo-menubar, where the filter was hard-coded to
/// LevelDB's file names.
public enum FSEventsWatch {
    /// Starts watching `directory` and returns the function that stops it.
    ///
    /// **The returned closure must be called.** The event stream holds the only
    /// strong reference to its own state, so dropping the closure without
    /// calling it leaves the stream scheduled and firing for the life of the
    /// process. That is deliberate: the alternative — letting the object be
    /// freed while the stream still points at it — is a use-after-free, which
    /// is what this code did before. `DirectoryWatcher` always calls it, either
    /// on detach or via the root-change path, which stops the stream itself.
    ///
    /// `include` decides, from an event's full path, whether it is worth an
    /// `onChange`.
    @MainActor
    public static func open(
        directory: String,
        include: @escaping @Sendable (String) -> Bool,
        onChange: @escaping () -> Void,
        onError: @escaping () -> Void
    ) throws -> () -> Void {
        let stream = try Stream(directory: directory, include: include, onChange: onChange, onError: onError)
        return { stream.stop() }
    }

    @MainActor
    private final class Stream {
        private var ref: FSEventStreamRef?
        private let include: @Sendable (String) -> Bool
        private let onChange: () -> Void
        private let onError: () -> Void
        private var stopped = false

        init(
            directory: String,
            include: @escaping @Sendable (String) -> Bool,
            onChange: @escaping () -> Void,
            onError: @escaping () -> Void
        ) throws {
            self.include = include
            self.onChange = onChange
            self.onError = onError

            // The stream outlives every Swift reference the caller may drop, so
            // it owns a retain on this object and gives it back through
            // `release`. With `passUnretained` and no release callback, a
            // watcher released while attached leaves the stream scheduled with
            // `info` pointing at freed memory.
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(self).toOpaque(),
                retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<Stream>.fromOpaque(info).release()
                },
                copyDescription: nil
            )

            // `UseCFTypes` is not optional: without it `eventPaths` is a C
            // `char **`, and reading it as a CFArray sends a message to path
            // bytes. `FileEvents` is what gives each event its own file's path
            // for `include` to judge; without it an event names only the
            // directory. `WatchRoot` turns the directory being replaced into
            // a reported death rather than a silently dead watch.
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Stream.callback,
                &context,
                [directory] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                flags
            ) else {
                // `FSEventStreamCreate` never ran, so nothing will ever call
                // `release` for the retain above.
                Unmanaged.passUnretained(self).release()
                throw FSEventsWatchError.couldNotStart(directory)
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw FSEventsWatchError.couldNotStart(directory)
            }
            ref = stream
        }

        func stop() {
            guard let stream = ref, !stopped else { return }
            stopped = true
            ref = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard !stopped else { return }
            var rootChanged = false
            var relevant = false
            for (path, flag) in zip(paths, flags) {
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
                // When events coalesce or are dropped, the individual names are
                // gone and the path degrades to the watched directory. Under
                // that load the file may well have changed with the rest, so it
                // counts as a reason to re-read rather than something to filter
                // out. A spare read costs one small file.
                let dropped = flag & FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped
                ) != 0
                if dropped || include(path) { relevant = true }
            }
            if rootChanged {
                stop()
                onError()
                return
            }
            if relevant { onChange() }
        }

        private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            // The stream was scheduled on the main queue, so this runs there.
            MainActor.assumeIsolated { stream.handle(paths: paths, flags: flags) }
        }
    }
}
