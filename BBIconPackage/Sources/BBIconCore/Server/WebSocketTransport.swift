import Foundation

public enum TransportFrame: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
}

public struct TransportClose: Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// A header value may be a credential, so a description, debug description,
/// or `dump` of a request names the header fields and never their values.
public struct TransportRequest: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let subprotocols: [String]

    public init(url: URL, headers: [String: String] = [:], subprotocols: [String] = []) {
        self.url = url
        self.headers = headers
        self.subprotocols = subprotocols
    }
}

extension TransportRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "TransportRequest(\(url.absoluteString), headers: \(redactedHeaderNames(headers)), subprotocols: \(subprotocols))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["url": url, "headers": redactedHeaderNames(headers), "subprotocols": subprotocols],
            displayStyle: .struct
        )
    }
}

/// The header fields a value carries, sorted, without their values: what a
/// description may show of a target's headers.
func redactedHeaderNames(_ headers: [String: String]) -> [String] {
    headers.keys.sorted()
}

/// `text` with every header value in `headers` replaced, and, for a `Cookie`
/// header, each cookie's value on its own too: a server or transport that
/// echoes a cookie back may quote only its value. Longest first, so a value
/// that contains another is replaced whole.
func scrubbingHeaderValues(_ headers: [String: String], from text: String) -> String {
    var secrets: Set<String> = []
    for (name, value) in headers {
        secrets.insert(value)
        guard name.caseInsensitiveCompare("Cookie") == .orderedSame else { continue }
        for pair in value.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            secrets.insert(pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }
    return secrets
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
        .reduce(text) { $0.replacingOccurrences(of: $1, with: Pairing.redacted) }
}

/// One WebSocket-shaped connection. `URLSessionWebSocketTransport` is the real
/// one; tests drive a fake. Every callback fires on the main actor.
///
/// Ported from paseo-menubar's `DaemonTransport`.
@MainActor
public protocol WebSocketTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onFrame: ((TransportFrame) -> Void)? { get set }
    var onClose: ((TransportClose) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect()
    func send(_ frame: TransportFrame)
    func close(code: Int, reason: String)
}

public typealias TransportFactory = @MainActor (TransportRequest) -> any WebSocketTransport
