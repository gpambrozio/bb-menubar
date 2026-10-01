import Foundation
@testable import BBIconCore

/// A transport the test drives by hand. Records what the code under test sent
/// and lets the test play the server's side. Ported from paseo-menubar.
///
/// It keeps its callbacks after `close`, the way a real socket's late delegate
/// calls outlive it, so a test can prove the session ignores a transport it
/// has already replaced.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onOpen: (() -> Void)?
    var onFrame: ((TransportFrame) -> Void)?
    var onClose: ((TransportClose) -> Void)?
    var onError: ((String) -> Void)?

    let request: TransportRequest
    private(set) var connectCalls = 0
    private(set) var sent: [TransportFrame] = []
    private(set) var closedWith: TransportClose?

    init(request: TransportRequest) {
        self.request = request
    }

    var sentText: [String] {
        sent.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    func connect() { connectCalls += 1 }
    func send(_ frame: TransportFrame) { sent.append(frame) }
    func close(code: Int, reason: String) {
        guard closedWith == nil else { return }
        closedWith = TransportClose(code: code, reason: reason)
    }

    func simulateOpen() { onOpen?() }
    func simulateText(_ text: String) { onFrame?(.text(text)) }
    func simulateBinary(_ bytes: [UInt8]) { onFrame?(.binary(bytes)) }
    func simulateClose(code: Int = 1006, reason: String = "") { onClose?(TransportClose(code: code, reason: reason)) }
    func simulateError(_ message: String) { onError?(message) }
}

@MainActor
final class FakeTransportFactory {
    private(set) var transports: [FakeTransport] = []

    func make(_ request: TransportRequest) -> any WebSocketTransport {
        let transport = FakeTransport(request: request)
        transports.append(transport)
        return transport
    }

    var last: FakeTransport? { transports.last }
}

/// Lets tasks the code under test spawned run to their next suspension point.
/// Enough for a "nothing else happened" check; a check that something *did*
/// happen uses `settle(until:)`, which does not depend on a yield count.
@MainActor
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// Yields until `condition` holds, or gives up after a bound so a broken
/// session fails the test's own expectation instead of hanging it.
@MainActor
func settle(until condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}
