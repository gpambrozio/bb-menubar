import Foundation

/// What bb.app says about itself in its runtime file: the process that wrote
/// it and the server it serves.
public struct RuntimeInfo: Equatable, Sendable {
    public let pid: Int32
    public let serverURL: URL
    public let version: String?

    public init(pid: Int32, serverURL: URL, version: String?) {
        self.pid = pid
        self.serverURL = serverURL
        self.version = version
    }
}

public enum RuntimeFileError: MessageError {
    /// The file was read but does not say where bb is. The detail names the field.
    case malformed(String)
    /// The file exists but could not be read, for example for lack of permission.
    case unreadable(String)

    public var message: String {
        switch self {
        case .malformed(let detail), .unreadable(let detail):
            "bb's runtime file could not be read: \(detail)"
        }
    }
}

/// `~/.bb/bb-app-runtime.json`, which bb.app writes while it runs:
///
///     { "entryPath": "…/bb-app-bridge.mjs", "pid": 16746,
///       "serverUrl": "http://127.0.0.1:38886", "startedAt": "…",
///       "surface": "desktop", "version": "0.44.0" }
///
/// Only `pid` and `serverUrl` are required. Every other field is ignored, so
/// a bb that adds one does not break discovery.
public enum RuntimeFile {
    public static let fileName = "bb-app-runtime.json"

    public static func directory(home: String) -> String {
        home + "/.bb"
    }

    /// Whether a watch event under `directory(home:)` can mean the runtime
    /// file changed. The prefix, rather than the exact name, also passes the
    /// temp file of an atomic write, whose rename is the event that matters.
    public static func isRuntimeFileEvent(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("bb-app-runtime")
    }

    private static let pidRange = "from 1 to \(Int32.max)"

    /// Throws `RuntimeFileError.malformed` naming the first field it cannot use.
    public static func parse(_ data: Data) throws -> RuntimeInfo {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RuntimeFileError.malformed("it is not a JSON object")
        }
        return RuntimeInfo(
            pid: try pid(object["pid"]),
            serverURL: try serverURL(object["serverUrl"]),
            version: object["version"] as? String
        )
    }

    /// A pid is a `pid_t`, so anything outside `1...Int32.max` is refused
    /// rather than truncated: truncating would make `kill(pid, 0)` probe some
    /// other process, and 0 or a negative value probes a whole process group.
    private static func pid(_ value: Any?) throws -> Int32 {
        guard let value else { throw RuntimeFileError.malformed("pid is missing") }
        // JSONSerialization hands back `true` and `false` as NSNumber, and
        // `NSNumber as? Int32` accepts them as 1 and 0. A pid of `true` is
        // not a pid.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              // Exact conversion: fails for 1.5 and for anything past Int32.
              let pid = number as? Int32,
              pid >= 1
        else {
            throw RuntimeFileError.malformed("pid is not a whole number \(pidRange)")
        }
        return pid
    }

    private static func serverURL(_ value: Any?) throws -> URL {
        guard let value else { throw RuntimeFileError.malformed("serverUrl is missing") }
        guard let text = value as? String,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty
        else {
            throw RuntimeFileError.malformed("serverUrl is not an http or https URL with a host")
        }
        return url
    }
}
