import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case online
    /// Sign-in failed or the connection was lost; the message is ready to show to the user.
    case failed(String)

    public var isOnline: Bool {
        return self == .online
    }

    /// The failure message, if any.
    public var errorMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
}

/// Presence as the app shows it. Incoming `away`, `xa` and `dnd` all count as away.
public enum PresenceShow: String, Sendable, CaseIterable {
    case available
    case away
    case offline
}

/// Roster subscription state (RFC 6121).
public enum RosterSubscription: String, Sendable, CaseIterable {
    case none
    case to
    case from
    case both
}

/// A roster entry with its aggregated presence.
public struct Buddy: Identifiable, Equatable, Sendable {
    /// Always a bare JID.
    public var jid: JID
    public var name: String?
    public var subscription: RosterSubscription
    /// `"subscribe"` while our subscription request is waiting for their approval.
    public var ask: String?
    public var groups: [String]
    /// Best presence over all of the buddy's resources.
    public var presence: PresenceShow
    /// Status message of the resource that determines `presence`.
    public var statusText: String?

    public init(jid: JID,
                name: String? = nil,
                subscription: RosterSubscription = .none,
                ask: String? = nil,
                groups: [String] = [],
                presence: PresenceShow = .offline,
                statusText: String? = nil) {
        self.jid = jid.bareJID
        self.name = name
        self.subscription = subscription
        self.ask = ask
        self.groups = groups
        self.presence = presence
        self.statusText = statusText
    }

    public var id: BareJID {
        return jid.bare
    }

    /// The roster name, or the bare JID when there is none.
    public var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return jid.bareString
    }

    public var isAwaitingAuthorization: Bool {
        return ask == "subscribe"
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    /// Locally unique (a UUID string); stanza ids from other clients are not reliable.
    public let id: String
    public let from: JID
    public let to: JID
    public let body: String
    public let date: Date
    public let isFromMe: Bool
    /// The stanza's `id` attribute, if it had one.
    public let stanzaID: String?

    public init(id: String = UUID().uuidString,
                from: JID,
                to: JID,
                body: String,
                date: Date = Date(),
                isFromMe: Bool,
                stanzaID: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.body = body
        self.date = date
        self.isFromMe = isFromMe
        self.stanzaID = stanzaID
    }
}

/// Errors from `XMPPClient`, each with a message fit for the user.
public enum XMPPError: Error, Equatable, LocalizedError {
    case invalidJID
    case tlsNotOffered
    case tlsRefused
    case tlsFailed(String)
    case noSupportedMechanism
    case authenticationFailed(condition: String, text: String?)
    case serverSignatureInvalid
    case hostNotFound(String)
    case connectionFailed(String)
    case connectionClosed
    case connectionLost
    case timedOut
    case streamError(condition: String, text: String?)
    case bindFailed(String)
    case protocolError(String)

    public var userMessage: String {
        switch self {
        case .invalidJID:
            return "That doesn't look like a Jabber ID. Use the form name@example.com."
        case .tlsNotOffered:
            return "The server doesn't offer an encrypted connection (STARTTLS), so CarpetChair won't sign in."
        case .tlsRefused:
            return "The server refused to start an encrypted connection."
        case .tlsFailed(let detail):
            return detail.isEmpty ? "The secure (TLS) connection failed." : "The secure (TLS) connection failed: \(detail)"
        case .noSupportedMechanism:
            return "The server doesn't offer a sign-in method CarpetChair supports."
        case .authenticationFailed(let condition, let text):
            switch condition {
            case "not-authorized", "invalid-authzid":
                return "Wrong Jabber ID or password"
            case "account-disabled":
                return "This account has been disabled."
            case "credentials-expired":
                return "Your password has expired."
            case "temporary-auth-failure":
                return "The server couldn't sign you in right now. Try again later."
            case "encryption-required":
                return "The server requires encryption for this sign-in method."
            default:
                if let text = text, !text.isEmpty {
                    return "Sign-in failed: \(text)"
                }
                return "Sign-in failed."
            }
        case .serverSignatureInvalid:
            return "The server could not prove it knows your password. The connection may have been tampered with."
        case .hostNotFound(let host):
            return "Couldn't find the server \(host). Check the Jabber ID and your internet connection."
        case .connectionFailed(let detail):
            return detail.isEmpty ? "Couldn't connect to the server." : "Couldn't connect to the server: \(detail)"
        case .connectionClosed:
            return "The server closed the connection."
        case .connectionLost:
            return "The connection to the server was lost."
        case .timedOut:
            return "The server didn't respond in time."
        case .streamError(let condition, let text):
            switch condition {
            case "conflict":
                return "You were signed out because this account signed in from another place."
            case "system-shutdown":
                return "The server is shutting down."
            case "host-unknown":
                return "The server doesn't host this Jabber domain."
            case "policy-violation":
                return "The server closed the connection (policy violation)."
            default:
                if let text = text, !text.isEmpty {
                    return "The server closed the connection: \(text)"
                }
                return "The server closed the connection (\(condition))."
            }
        case .bindFailed(let detail):
            return "The server didn't accept this session (\(detail))."
        case .protocolError(let detail):
            return "Something went wrong talking to the server: \(detail)"
        }
    }

    public var errorDescription: String? {
        return userMessage
    }
}

/// XML namespaces used by the client.
public enum XMPPNamespace {
    public static let client = "jabber:client"
    public static let streams = "http://etherx.jabber.org/streams"
    public static let tls = "urn:ietf:params:xml:ns:xmpp-tls"
    public static let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
    public static let bind = "urn:ietf:params:xml:ns:xmpp-bind"
    public static let session = "urn:ietf:params:xml:ns:xmpp-session"
    public static let roster = "jabber:iq:roster"
    public static let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
    public static let ping = "urn:xmpp:ping"
    public static let delay = "urn:xmpp:delay"
}
