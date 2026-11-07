import Foundation
import Network

/// A loopback HTTP server that answers every request with `401 Unauthorized` and a Basic challenge (#93).
///
/// It lets a test run a real `git fetch` that needs credentials without any network: git then looks for a credential
/// helper, an askpass program, or a terminal prompt, which is exactly what SEC-T12-01/02 check. It speaks just enough
/// HTTP/1.1 for git's smart-HTTP discovery request (`GET …/info/refs?service=git-upload-pack`).
final class LocalHTTPAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "overgrove.tests.http-auth")
    private let lock = NSLock()
    private var requests = 0

    /// The bound loopback port.
    let port: UInt16

    /// Requests answered so far.
    var requestCount: Int { lock.withLock { requests } }

    /// `http://127.0.0.1:<port>/<path>`.
    func url(_ path: String = "repo.git", userInfo: String? = nil) -> String {
        "http://\(userInfo.map { "\($0)@" } ?? "")127.0.0.1:\(port)/\(path)"
    }

    static func start() async throws -> LocalHTTPAuthServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "overgrove.tests.http-auth.start")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let resume = once.resume
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { resume(.success(port)) }
                case .failed(let error):
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }  // replaced below once the server exists
            listener.start(queue: queue)
        }
        let server = LocalHTTPAuthServer(listener: listener, port: port)
        listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        return server
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    /// Resumes a continuation at most once; the listener reports several states.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?

        init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

        func resume(_ result: Result<UInt16, Error>) {
            let pending = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }

    // MARK: - Connections

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(on: connection, buffered: Data())
    }

    /// Reads until the end of the request headers, then answers 401 and closes the connection.
    private func receiveHeaders(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var request = buffered
            if let data { request.append(data) }
            let headersEnded = request.range(of: Data("\r\n\r\n".utf8)) != nil
            guard headersEnded || isComplete || error != nil || request.count > 64 * 1024 else {
                receiveHeaders(on: connection, buffered: request)
                return
            }
            lock.withLock { requests += 1 }
            let response = """
                HTTP/1.1 401 Unauthorized\r
                WWW-Authenticate: Basic realm="overgrove-test"\r
                Content-Length: 0\r
                Connection: close\r
                \r

                """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
