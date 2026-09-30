import AppKit
import BBIconCore

/// The five bucket glyphs, as template images so they invert with the menu
/// bar. `npm run icons` rasterizes them into this target's resources: four
/// lucide glyphs and the bb mark for `done`. Ported from paseo-menubar.
@MainActor
enum TrayIcons {
    private static var cache: [ThreadBucket: NSImage] = [:]

    /// The resource bundle SwiftPM emits for this target, `<package>_<target>`.
    /// `native-bundle.mjs` copies it into the app's `Contents/Resources`, and
    /// its test holds the two names together.
    static let resourceBundleName = "BBIconPackage_BBIcon.bundle"

    /// Found by `ResourceBundleLocator` rather than `Bundle.module`, whose
    /// generated accessor traps when the bundle is not where the builder's
    /// SwiftPM expects it. Nil when it is nowhere, which `image` names.
    private static let resourceBundle: Bundle? = {
        let main = Bundle.main
        let url = ResourceBundleLocator.locate(
            bundleName: resourceBundleName,
            resourceURL: main.resourceURL,
            bundleURL: main.bundleURL,
            executableURL: main.executableURL
        ) { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return url.flatMap(Bundle.init(url:))
    }()

    /// A missing file yields an empty image rather than an error, and an empty
    /// image is a status item with no visible icon: no way to open the menu,
    /// no way to quit. The icons are generated rather than committed, so this
    /// is reachable from a build that skipped `npm run icons`.
    static func image(for bucket: ThreadBucket) throws -> NSImage {
        if let cached = cache[bucket] { return cached }
        guard let bundle = resourceBundle else { throw TrayIconError.missingBundle(resourceBundleName) }
        let name = TrayViewModelBuilder.iconNames[bucket] ?? bucket.rawValue
        // Both rasterizations, not just the 1x one. `NSImage(contentsOf:)` on a
        // single file yields a single representation, so a Retina menu bar
        // would draw 16px art in a 32px box. The PNGs also carry a 288-DPI
        // pHYs chunk, so each representation loads claiming to be 4pt square —
        // pinning both to the 16pt box is what makes AppKit choose by scale
        // rather than size.
        let box = NSSize(width: 16, height: 16)
        let image = NSImage(size: box)
        // Both are required, not merely preferred. The generator writes the
        // pair in one pass, so a half-written set means a half-run generator —
        // and accepting the survivor would put 1x art on a Retina menu bar
        // silently.
        for suffix in ["", "@2x"] {
            let file = "\(name)Template\(suffix)"
            guard let url = bundle.url(forResource: file, withExtension: "png", subdirectory: "TrayIcons"),
                  let rep = NSImageRep(contentsOf: url) else {
                throw TrayIconError.missing(file)
            }
            rep.size = box
            image.addRepresentation(rep)
        }
        guard image.isValid else { throw TrayIconError.missing("\(name)Template") }
        image.isTemplate = true
        cache[bucket] = image
        return image
    }

    /// Loads every bucket once, so a build missing its icons fails at launch
    /// with a name rather than showing a blank item.
    static func preflight() throws {
        for bucket in TrayViewModelBuilder.sectionOrder { _ = try image(for: bucket) }
    }
}

enum TrayIconError: MessageError {
    case missing(String)
    case missingBundle(String)

    var message: String {
        switch self {
        case .missing(let file): "Missing tray icon: \(file).png. Run `npm run icons`."
        case .missingBundle(let name):
            "Missing \(name), which holds the tray icons, in the app's Resources and beside its executable. "
                + "Run `npm run icons`, then rebuild (`npm run dist` for the app)."
        }
    }
}
