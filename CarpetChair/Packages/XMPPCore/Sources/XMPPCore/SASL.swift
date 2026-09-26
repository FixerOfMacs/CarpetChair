import Foundation
import CryptoKit

/// SASL mechanisms the client supports, strongest first.
public enum SASLMechanism: String, Sendable, CaseIterable {
    case scramSHA256 = "SCRAM-SHA-256"
    case scramSHA1 = "SCRAM-SHA-1"
    case plain = "PLAIN"

    /// Picks SCRAM-SHA-256 > SCRAM-SHA-1 > PLAIN from what the server offers.
    /// PLAIN is only chosen when TLS is active.
    public static func preferred(from offered: [String], tlsActive: Bool) -> SASLMechanism? {
        let names = Set(offered.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
        if names.contains(SASLMechanism.scramSHA256.rawValue) {
            return .scramSHA256
        }
        if names.contains(SASLMechanism.scramSHA1.rawValue) {
            return .scramSHA1
        }
        if tlsActive && names.contains(SASLMechanism.plain.rawValue) {
            return .plain
        }
        return nil
    }
}

public enum SASLError: Error, Equatable {
    case noSupportedMechanism
    case invalidServerMessage(String)
    case nonceMismatch
    case unsupportedIterationCount(Int)
    case serverError(String)
    case serverSignatureMismatch
    case missingServerSignature
    case outOfOrder
}

public enum SASL {
    /// SASLprep-lite for SCRAM user names: `=` becomes `=3D`, `,` becomes `=2C`.
    public static func escapeUsername(_ username: String) -> String {
        return username
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
    }

    /// The PLAIN initial response: `[authzid] NUL authcid NUL password`.
    public static func plainMessage(username: String, password: String, authorizationID: String? = nil) -> Data {
        var bytes: [UInt8] = []
        if let authorizationID = authorizationID {
            bytes.append(contentsOf: Array(authorizationID.utf8))
        }
        bytes.append(0)
        bytes.append(contentsOf: Array(username.utf8))
        bytes.append(0)
        bytes.append(contentsOf: Array(password.utf8))
        return Data(bytes)
    }
}

/// Client side of SCRAM (RFC 5802 / RFC 7677) without channel binding.
///
/// 1. send `clientFirstMessage`
/// 2. pass the server-first message to `clientFinalMessage(serverFirstMessage:)` and send the result
/// 3. pass the server-final message to `verifyServerFinalMessage(_:)`; it throws if the
///    server's signature is wrong.
public final class SCRAMAuthenticator {
    public enum Algorithm: Sendable {
        case sha1
        case sha256
    }

    /// Refuse absurd iteration counts from the server (a denial-of-service vector).
    public static let maximumIterations = 1_000_000

    public let algorithm: Algorithm
    public let clientNonce: String
    /// `n,,n=<user>,r=<nonce>` — send this (base64) in `<auth>`.
    public let clientFirstMessage: String
    /// True once the server's final message carried a valid signature.
    public private(set) var isServerVerified = false
    /// True once `clientFinalMessage(serverFirstMessage:)` succeeded.
    public private(set) var hasProducedClientFinal = false

    private static let gs2Header = "n,,"

    private let clientFirstMessageBare: String
    private let passwordBytes: [UInt8]
    private var expectedServerSignature: [UInt8]? = nil

    /// - Parameter clientNonce: inject a fixed nonce for tests; otherwise a random one is used.
    public init(algorithm: Algorithm, username: String, password: String, clientNonce: String? = nil) {
        let nonce = clientNonce ?? SCRAMAuthenticator.makeNonce()
        let bare = "n=" + SASL.escapeUsername(username) + ",r=" + nonce
        self.algorithm = algorithm
        self.clientNonce = nonce
        self.clientFirstMessageBare = bare
        self.clientFirstMessage = SCRAMAuthenticator.gs2Header + bare
        self.passwordBytes = Array(password.precomposedStringWithCompatibilityMapping.utf8)
    }

    public func clientFinalMessage(serverFirstMessage: String) throws -> String {
        let fields = try SCRAMAuthenticator.parseFields(serverFirstMessage)
        if let error = fields["e"] {
            throw SASLError.serverError(error)
        }
        if fields["m"] != nil {
            throw SASLError.invalidServerMessage("unsupported mandatory extension")
        }
        guard let nonce = fields["r"], let saltText = fields["s"], let iterationText = fields["i"] else {
            throw SASLError.invalidServerMessage(serverFirstMessage)
        }
        guard nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else {
            throw SASLError.nonceMismatch
        }
        guard let salt = Data(base64Encoded: saltText), !salt.isEmpty else {
            throw SASLError.invalidServerMessage("bad salt")
        }
        guard let iterations = Int(iterationText) else {
            throw SASLError.invalidServerMessage("bad iteration count")
        }
        guard iterations >= 1 && iterations <= SCRAMAuthenticator.maximumIterations else {
            throw SASLError.unsupportedIterationCount(iterations)
        }

        let channelBinding = Data(SCRAMAuthenticator.gs2Header.utf8).base64EncodedString()
        let finalWithoutProof = "c=" + channelBinding + ",r=" + nonce
        let authMessage = Array((clientFirstMessageBare + "," + serverFirstMessage + "," + finalWithoutProof).utf8)

        let saltedPassword = SCRAMCrypto.pbkdf2(algorithm, password: passwordBytes, salt: Array(salt), iterations: iterations)
        let clientKey = SCRAMCrypto.hmac(algorithm, keyBytes: saltedPassword, message: Array("Client Key".utf8))
        let storedKey = SCRAMCrypto.hash(algorithm, clientKey)
        let clientSignature = SCRAMCrypto.hmac(algorithm, keyBytes: storedKey, message: authMessage)
        var proof = clientKey
        for index in 0..<proof.count {
            proof[index] ^= clientSignature[index]
        }
        let serverKey = SCRAMCrypto.hmac(algorithm, keyBytes: saltedPassword, message: Array("Server Key".utf8))
        expectedServerSignature = SCRAMCrypto.hmac(algorithm, keyBytes: serverKey, message: authMessage)
        hasProducedClientFinal = true

        return finalWithoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    /// Checks `v=<ServerSignature>`; throws `SASLError.serverSignatureMismatch` if it is wrong.
    public func verifyServerFinalMessage(_ message: String) throws {
        guard let expected = expectedServerSignature else {
            throw SASLError.outOfOrder
        }
        let fields = try SCRAMAuthenticator.parseFields(message)
        if let error = fields["e"] {
            throw SASLError.serverError(error)
        }
        guard let verifier = fields["v"], let signature = Data(base64Encoded: verifier) else {
            throw SASLError.invalidServerMessage(message)
        }
        guard SCRAMCrypto.constantTimeEquals(Array(signature), expected) else {
            throw SASLError.serverSignatureMismatch
        }
        isServerVerified = true
    }

    static func parseFields(_ message: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        for part in message.split(separator: ",", omittingEmptySubsequences: true) {
            guard let equals = part.firstIndex(of: "="),
                  part.distance(from: part.startIndex, to: equals) == 1 else {
                throw SASLError.invalidServerMessage(message)
            }
            let key = String(part[part.startIndex..<equals])
            let value = String(part[part.index(after: equals)...])
            if fields[key] == nil {
                fields[key] = value
            }
        }
        return fields
    }

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in 0..<bytes.count {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
    }
}

/// The primitives SCRAM needs, on top of CryptoKit.
enum SCRAMCrypto {
    static func hash(_ algorithm: SCRAMAuthenticator.Algorithm, _ data: [UInt8]) -> [UInt8] {
        switch algorithm {
        case .sha1:
            return Array(Insecure.SHA1.hash(data: data))
        case .sha256:
            return Array(SHA256.hash(data: data))
        }
    }

    static func hmac(_ algorithm: SCRAMAuthenticator.Algorithm, keyBytes: [UInt8], message: [UInt8]) -> [UInt8] {
        return hmac(algorithm, key: SymmetricKey(data: keyBytes), message: message)
    }

    static func hmac(_ algorithm: SCRAMAuthenticator.Algorithm, key: SymmetricKey, message: [UInt8]) -> [UInt8] {
        switch algorithm {
        case .sha1:
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        }
    }

    /// PBKDF2 (RFC 8018) with HMAC-H, producing one block (hLen bytes) — SCRAM's `Hi()`.
    static func pbkdf2(_ algorithm: SCRAMAuthenticator.Algorithm, password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var previous = hmac(algorithm, key: key, message: block)
        var result = previous
        var round = 1
        while round < iterations {
            previous = hmac(algorithm, key: key, message: previous)
            for index in 0..<result.count {
                result[index] ^= previous[index]
            }
            round += 1
        }
        return result
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        if lhs.count != rhs.count {
            return false
        }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
