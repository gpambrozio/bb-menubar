import Foundation

/// Finds a SwiftPM resource bundle without `Bundle.module`.
///
/// The accessor SwiftPM generates for `Bundle.module` depends on the builder:
/// swift-6.1's native build system looks only beside `Bundle.main.bundleURL`
/// (for an app, the `.app` itself rather than `Contents/Resources`, where
/// `npm run dist` puts the bundle) and then at the absolute build path, and
/// calls `fatalError` when neither exists — so an app moved to another Mac,
/// or run after `.build` is gone, would trap before the menu bar item exists.
/// This looks in the same places a newer accessor does, in a fixed order, and
/// answers nil instead, which the caller names.
public enum ResourceBundleLocator {
    /// The first `<directory>/<bundleName>` that exists, trying in order:
    /// `resourceURL` (a packaged app's `Contents/Resources`), `bundleURL`
    /// (SwiftPM's own convention), and the executable's directory (`swift
    /// run`, tests). Nil when there is none. A nil candidate is skipped.
    public static func locate(
        bundleName: String,
        resourceURL: URL?,
        bundleURL: URL?,
        executableURL: URL?,
        fileExists: (URL) -> Bool
    ) -> URL? {
        let directories = [resourceURL, bundleURL, executableURL?.deletingLastPathComponent()]
        for case let directory? in directories {
            let candidate = directory.appendingPathComponent(bundleName, isDirectory: true)
            if fileExists(candidate) { return candidate }
        }
        return nil
    }
}
