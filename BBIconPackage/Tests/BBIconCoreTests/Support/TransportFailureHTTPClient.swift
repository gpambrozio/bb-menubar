import Foundation
import BBIconCore

/// An HTTP client whose every request fails before an answer arrives, as a
/// relay that cannot be reached does. It records the requests, so a test can
/// still check what would have been sent.
actor TransportFailureHTTPClient: HTTPClient {
    private let error: any Error
    private(set) var requests: [URLRequest] = []

    init(_ error: any Error) {
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        throw error
    }
}

/// A transport failure that names the credential it was sent with, so a test
/// can show the credential is scrubbed from any text built around it.
struct CredentialEchoingError: MessageError {
    let credential: String
    var message: String { "connection reset while sending \(credential)" }
}
