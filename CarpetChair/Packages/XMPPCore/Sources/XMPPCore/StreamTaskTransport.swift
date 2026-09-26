import Foundation
import Security

/// `XMPPTransport` on top of `URLSessionStreamTask`.
///
/// STARTTLS uses `startSecureConnection()`. The server certificate is
/// validated by the system trust store, with the policy's host name set to
/// the XMPP domain passed to `startTLS(serverName:)` (RFC 7590), not the
/// SRV target. Validation is never disabled.
public final class StreamTaskTransport: NSObject, XMPPTransport, URLSessionStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var host = ""
    private var tlsServerName: String?
    private var secure = false
    private var storedError: Error?
    private var reachedEOF = false

    /// Timeout for a single write, in seconds.
    public var writeTimeout: TimeInterval = 60

    public override init() {
        super.init()
    }

    public var isSecure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return secure
    }

    public func connect(host: String, port: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "XMPPCore.StreamTaskTransport"
        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let newTask = newSession.streamTask(withHostName: host, port: port)
        install(session: newSession, task: newTask, host: host)
        newTask.resume()
    }

    public func send(_ data: Data) {
        guard let currentTask = activeTask() else { return }
        currentTask.write(data, timeout: writeTimeout) { [weak self] error in
            guard let self = self, let error = error else { return }
            // Remember the first failure and kill the connection so the
            // pending read reports it.
            self.lock.lock()
            if self.storedError == nil {
                self.storedError = error
            }
            let failedTask = self.task
            self.lock.unlock()
            failedTask?.cancel()
        }
    }

    public func receive() async throws -> Data? {
        let state = readState()
        let hostName = state.host
        if let pendingError = state.error {
            throw StreamTaskTransport.map(pendingError, host: hostName, tlsStarted: state.secure)
        }
        guard let readTask = state.task, !state.atEOF else {
            return nil
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            // A timeout of 0 means the read never times out; the client sends
            // whitespace keepalives to notice dead connections.
            readTask.readData(ofMinLength: 1, maxLength: 65536, timeout: 0) { [weak self] data, atEOF, error in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.lock.lock()
                if let error = error, self.storedError == nil {
                    self.storedError = error
                }
                if atEOF {
                    self.reachedEOF = true
                }
                let firstError = self.storedError
                let tlsStarted = self.secure
                self.lock.unlock()

                if let data = data, !data.isEmpty {
                    // Deliver what arrived; a stored error or EOF is reported next time.
                    continuation.resume(returning: data)
                } else if let firstError = firstError {
                    continuation.resume(throwing: StreamTaskTransport.map(firstError, host: hostName, tlsStarted: tlsStarted))
                } else if atEOF {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func startTLS(serverName: String) async throws {
        guard let tlsTask = markSecure(serverName: serverName) else {
            throw TransportError.closed
        }
        tlsTask.startSecureConnection()
    }

    public func close() {
        lock.lock()
        let closingTask = task
        let closingSession = session
        task = nil
        session = nil
        lock.unlock()

        guard let finalTask = closingTask else { return }
        // Let queued writes (e.g. </stream:stream>) go out, then tear down.
        finalTask.closeWrite()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            finalTask.cancel()
            // A URLSession keeps a strong reference to its delegate until it is invalidated.
            closingSession?.invalidateAndCancel()
        }
    }

    // MARK: - Locked state access (synchronous: NSLock must not be used directly in async code)

    private struct ReadState {
        var task: URLSessionStreamTask?
        var error: Error?
        var atEOF: Bool
        var host: String
        var secure: Bool
    }

    private func activeTask() -> URLSessionStreamTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func readState() -> ReadState {
        lock.lock()
        defer { lock.unlock() }
        return ReadState(task: task, error: storedError, atEOF: reachedEOF, host: host, secure: secure)
    }

    private func install(session newSession: URLSession, task newTask: URLSessionStreamTask, host newHost: String) {
        lock.lock()
        let oldSession = session
        let oldTask = task
        session = newSession
        task = newTask
        host = newHost
        tlsServerName = nil
        secure = false
        storedError = nil
        reachedEOF = false
        lock.unlock()
        oldTask?.cancel()
        oldSession?.invalidateAndCancel()
    }

    /// Records that TLS is starting and returns the task to upgrade (nil when closed).
    private func markSecure(serverName: String) -> URLSessionStreamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentTask = task else { return nil }
        tlsServerName = serverName
        secure = true
        return currentTask
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lock.lock()
        let expectedName = tlsServerName ?? host
        lock.unlock()

        // Validate the chain against the system roots, for the XMPP domain.
        let policy = SecPolicyCreateSSL(true, expectedName as CFString)
        let status = SecTrustSetPolicies(trust, policy)
        guard status == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var trustError: CFError?
        if SecTrustEvaluateWithError(trust, &trustError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Error mapping

    static func map(_ error: Error, host: String, tlsStarted: Bool) -> Error {
        if error is TransportError {
            return error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return TransportError.hostNotFound(host)
            case .timedOut:
                return TransportError.timedOut
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return TransportError.tlsFailed(urlError.localizedDescription)
            case .cancelled:
                // Refusing the server's certificate cancels the task.
                if tlsStarted {
                    return TransportError.tlsFailed("The server's certificate is not valid for this Jabber server.")
                }
                return TransportError.closed
            default:
                return TransportError.connectionFailed(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain && nsError.code <= -9800 && nsError.code >= -9899 {
            // Secure Transport / Network.framework errSSL* codes.
            return TransportError.tlsFailed(nsError.localizedDescription)
        }
        return TransportError.connectionFailed(nsError.localizedDescription)
    }
}
