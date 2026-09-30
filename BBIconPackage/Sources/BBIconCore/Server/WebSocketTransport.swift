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
