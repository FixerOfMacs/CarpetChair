import Foundation

/// Errors a transport reports. `StreamTaskTransport` maps system errors onto these.
public enum TransportError: Error, Equatable {
    /// DNS could not resolve the host.
    case hostNotFound(String)
    /// TCP connection failed or was lost; the associated value is a human-readable reason.
    case connectionFailed(String)
    /// The TLS handshake or certificate validation failed.
    case tlsFailed(String)
    case timedOut
    /// The transport is closed (or was never connected).
    case closed
}

/// A byte pipe to an XMPP server that can be upgraded to TLS in place (STARTTLS).
///
/// Reading is pull-based: the client calls `receive()` for the next chunk.
/// This matters for STARTTLS: `startTLS(serverName:)` must be called while no
/// read is outstanding (otherwise the TLS handshake would queue behind a read
/// that the server will never satisfy), and pull-based reading guarantees
/// that. `incoming` wraps the same thing as an `AsyncThrowingStream`.
public protocol XMPPTransport: AnyObject {
    /// True once `startTLS(serverName:)` has been called: from then on nothing
    /// is sent in plain text.
    var isSecure: Bool { get }

    /// Opens a TCP connection. Connection errors may surface here or on the
    /// first `receive()`.
    func connect(host: String, port: Int) async throws

    /// Queues bytes for sending. Write errors end the connection: the next
    /// (or pending) `receive()` throws.
    func send(_ data: Data)

    /// Waits for the next chunk of bytes. Returns nil when the server closed
    /// the connection cleanly; throws (ideally a `TransportError`) when it
    /// was lost. Only one `receive()` may be outstanding at a time.
    func receive() async throws -> Data?

    /// Upgrades the connection to TLS, validating the certificate against
    /// `serverName` (the XMPP domain). Handshake errors surface on the next
    /// `receive()`.
    func startTLS(serverName: String) async throws

    /// Closes the connection. Pending and later `receive()` calls finish.
    func close()
}

extension XMPPTransport {
    /// The received data as a stream; it ends on a clean close and throws
    /// the disconnect error otherwise.
    public var incoming: AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream<Data, Error>(unfolding: { try await self.receive() })
    }
}
