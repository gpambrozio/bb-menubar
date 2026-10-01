import Foundation
import Network

/// A one-answer HTTP server on 127.0.0.1, for seeing what `URLSession`
/// actually puts on the wire and what it makes of a refusal. It reads each
/// request's head, records it, answers every request with `response`, and
/// closes the connection. Nothing leaves the Mac.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "br.eng.gustavo.bb-menubar.tests.loopback")
    private let response: Data
    private let lock = NSLock()
    private var heads: [String] = []

    /// `status` and `reason` make the status line; the body is `body`.
    init(status: Int, reason: String, body: String = "") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let bodyData = Data(body.utf8)
        response = Data(
            ("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html\r\n"
                + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n").utf8
        ) + bodyData
    }

    /// The head (request line and headers) of every request, in order.
    var requestHeads: [String] { lock.withLock { heads } }

    /// Starts listening and returns the port, or throws if it cannot: a
    /// listener that fails, waits, or is cancelled before it is ready ends the
    /// wait rather than hanging the test.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.raise() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    guard resumed.raise() else { return }
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    // Waiting would wait forever for a loopback listener
                    // that cannot bind: give up and say why.
                    guard resumed.raise() else { return }
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard resumed.raise() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.lock.withLock { self.heads.append(head) }
                connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }
}

/// Set once, from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    /// Raises the flag; true only for the call that raised it.
    func raise() -> Bool {
        lock.withLock {
            defer { raised = true }
            return !raised
        }
    }
}

extension String {
    /// The value of header `name` in an HTTP request head, matching the name
    /// without case, or nil.
    func headerValue(_ name: String) -> String? {
        for line in components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
