import Foundation

/// `WebSocketTransport` over `URLSessionWebSocketTask`. Ported from
/// paseo-menubar unchanged but for the protocol's name and its handling of
/// cookies. A local bb's `/ws` needs no headers; a remote one's upgrade
/// carries the relay's session cookie (and the machine credential) in the
/// request's headers. bb's `/ws` needs no subprotocols; the request still
/// carries them so the port stays a port.
@MainActor
public final class URLSessionWebSocketTransport: WebSocketTransport {
    public var onOpen: (() -> Void)?
    public var onFrame: ((TransportFrame) -> Void)?
    public var onClose: ((TransportClose) -> Void)?
    public var onError: ((String) -> Void)?

    private let request: TransportRequest
    /// Internal to read, so a test can check the session refuses redirects.
    private(set) var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// The tail of the send chain, so frames keep their order.
    private var sendTail: Task<Void, Never> = Task {}
    private var closed = false
    /// Which socket the callbacks belong to. A cancelled receive loop and an
    /// invalidated session's delegate both keep running for a moment after
    /// `connect()` has replaced them, and both end in code that closes "the"
    /// socket. Without a generation to check, the predecessor tears down its
    /// successor. Incremented on every `connect()`.
    private var generation = 0

    public init(request: TransportRequest) {
        self.request = request
    }

    public func connect() {
        // A second connect has to leave nothing of the first behind. Without
        // this, `closed` stayed true from the previous `close()` — so `send`
        // refused every frame forever — while the old `URLSession` and its
        // strongly-retained delegate leaked with the socket still open. A
        // silently dead channel. Production builds a fresh transport per
        // attempt, but the type should not punish a caller who does not.
        receiveTask?.cancel()
        sendTail.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        closed = false
        generation += 1
        // A fresh chain, not the cancelled predecessor: the first send after a
        // reconnect would otherwise await a cancelled task, and the old chain's
        // cancellation would surface through the new transport's `onError`.
        sendTail = Task {}

        let urlRequest = Self.urlRequest(for: request)
        let generation = self.generation
        let delegate = Delegate(
            onOpen: { [weak self] in
                Task { @MainActor in self?.deliverOpen(generation: generation) }
            },
            onClose: { [weak self] code, reason in
                Task { @MainActor in self?.finish(code: code, reason: reason, generation: generation) }
            }
        )
        let session = URLSession(configuration: Self.sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: urlRequest)
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    /// The upgrade request: the target's headers exactly as given. A remote
    /// bb's carry a `Cookie` header, the relay's desktop session, which
    /// `URLSession` would otherwise be free to replace with cookies from its
    /// store; `httpShouldHandleCookies = false` keeps the one set here.
    static func urlRequest(for request: TransportRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.subprotocols.isEmpty {
            urlRequest.setValue(request.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return urlRequest
    }

    /// Ephemeral, and with no cookie store at all: the only cookie an upgrade
    /// carries is the one its request names, and none it is answered with is
    /// kept, so no session outlives the dial it was minted for.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    /// Frames go out in the order they were handed over. `URLSessionWebSocketTask.send`
    /// is async, and one unstructured `Task` per frame does not preserve
    /// order: two sends can complete in either order. Each send therefore
    /// awaits the previous one.
    public func send(_ frame: TransportFrame) {
        guard let task, !closed else {
            onError?("Transport not connected")
            return
        }
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .text(let text): message = .string(text)
        case .binary(let bytes): message = .data(Data(bytes))
        }
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous.value
            do {
                try await task.send(message)
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    public func close(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        sendTail.cancel()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
        session?.finishTasksAndInvalidate()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): onFrame?(.text(text))
                case .data(let data): onFrame?(.binary([UInt8](data)))
                @unknown default: break
                }
            } catch {
                handleReceiveFailure(error, task: task)
                return
            }
        }
    }

    /// `receive()` throws when the socket ends for any reason. If the server
    /// sent a close frame, the task already carries its code and reason; a
    /// dropped connection or a failed handshake carries neither and reports
    /// as 1006 with the error text, which for a refused upgrade names the
    /// server's status.
    private func handleReceiveFailure(_ error: any Error, task: URLSessionWebSocketTask) {
        // `task === self.task` is the whole point: a receive loop cancelled by
        // `connect()` still throws and still lands here, and by then `closed`
        // has been reset, so the guard below passes and the predecessor closes
        // the socket its successor just opened — reporting a close the owner
        // never caused.
        guard !closed, task === self.task else { return }
        let text = Self.failureText(error, response: task.response)
        onError?(text)
        let closeCode = task.closeCode
        if closeCode == .invalid {
            finish(code: 1006, reason: text)
        } else {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            finish(code: closeCode.rawValue, reason: reason)
        }
    }

    /// What a socket that ended says about why. An upgrade the server
    /// answered with anything but 101 is named by that status: `URLSession`'s
    /// own text for it, "There was a bad response from the server.", does not
    /// say whether the server refused (a 401 from the relay) or broke.
    static func failureText(_ error: any Error, response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode != 101 {
            return "the server refused the connection (HTTP \(http.statusCode))"
        }
        return error.localizedDescription
    }

    private func deliverOpen(generation: Int) {
        guard generation == self.generation else { return }
        onOpen?()
    }

    private func finish(code: Int, reason: String, generation: Int? = nil) {
        // An invalidated session's delegate is retained by that session and has
        // no notion of which socket it belongs to, so a late `didCloseWith`
        // from the previous generation must not close the current one.
        if let generation, generation != self.generation { return }
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        session?.invalidateAndCancel()
        onClose?(TransportClose(code: code, reason: reason))
    }

    /// `Sendable` because `URLSession` calls it on its own queue; checked, not
    /// `@unchecked`, since its only state is two immutable `@Sendable` closures.
    /// Internal rather than private so its redirect refusal is tested.
    final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
        private let openHandler: @Sendable () -> Void
        private let closeHandler: @Sendable (Int, String) -> Void

        init(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Int, String) -> Void) {
            self.openHandler = onOpen
            self.closeHandler = onClose
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            openHandler()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            closeHandler(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }

        /// The upgrade never follows a redirect, for the reason
        /// `URLSessionHTTPClient` gives: it would carry the relay credential
        /// to the `Location` host. The 3xx fails the handshake instead.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
