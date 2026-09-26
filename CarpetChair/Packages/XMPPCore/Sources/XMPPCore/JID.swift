import Foundation

/// A bare Jabber ID (`local@domain`). The local part and domain are stored in
/// lower case, so two `BareJID`s that differ only in case are equal. Use it as
/// the key for per-contact state such as conversations.
public struct BareJID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let local: String?
    public let domain: String

    /// Returns nil when the parts are not a valid JID.
    public init?(local: String?, domain: String) {
        guard let parts = JIDValidation.validate(local: local, domain: domain) else { return nil }
        self.local = parts.local
        self.domain = parts.domain
    }

    /// Parses `local@domain` (a resource, if present, is dropped).
    public init?(_ string: String) {
        guard let jid = JID(string) else { return nil }
        self = jid.bare
    }

    /// Used internally for parts that are already validated and normalised.
    init(validatedLocal local: String?, domain: String) {
        self.local = local
        self.domain = domain
    }

    public var description: String {
        if let local = local {
            return local + "@" + domain
        }
        return domain
    }

    /// The same address as a `JID` without a resource.
    public var jid: JID {
        return JID(bare: self)
    }

    public static func < (lhs: BareJID, rhs: BareJID) -> Bool {
        return lhs.description < rhs.description
    }
}

/// A Jabber ID: `local@domain/resource`, where the local part and the resource
/// are optional.
///
/// Equality and hashing use the *bare* form: `a@b/phone == a@b/laptop` is
/// true. Use `isIdentical(to:)` when the resource matters.
public struct JID: Hashable, Sendable, CustomStringConvertible {
    public let local: String?
    public let domain: String
    public let resource: String?

    /// Parses `local@domain/resource`, `local@domain` or `domain`.
    /// Returns nil for malformed input (empty parts, forbidden characters).
    public init?(_ string: String) {
        var rest = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        var parsedResource: String? = nil
        if let slash = rest.firstIndex(of: "/") {
            let value = String(rest[rest.index(after: slash)...])
            if value.isEmpty { return nil }
            parsedResource = value
            rest = rest[..<slash]
        }
        var parsedLocal: String? = nil
        if let at = rest.firstIndex(of: "@") {
            parsedLocal = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        guard let parts = JIDValidation.validate(local: parsedLocal, domain: String(rest)) else { return nil }
        self.local = parts.local
        self.domain = parts.domain
        self.resource = parsedResource
    }

    public init(bare: BareJID, resource: String? = nil) {
        self.local = bare.local
        self.domain = bare.domain
        if let resource = resource, !resource.isEmpty {
            self.resource = resource
        } else {
            self.resource = nil
        }
    }

    public var bare: BareJID {
        return BareJID(validatedLocal: local, domain: domain)
    }

    /// This JID with the resource removed.
    public var bareJID: JID {
        return JID(bare: bare)
    }

    public var isBare: Bool {
        return resource == nil
    }

    /// The full string form, including the resource if there is one.
    public var description: String {
        if let resource = resource {
            return bare.description + "/" + resource
        }
        return bare.description
    }

    /// `local@domain` without the resource.
    public var bareString: String {
        return bare.description
    }

    public static func == (lhs: JID, rhs: JID) -> Bool {
        return lhs.bare == rhs.bare
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bare)
    }

    /// Full comparison, including the resource.
    public func isIdentical(to other: JID) -> Bool {
        return bare == other.bare && resource == other.resource
    }
}

enum JIDValidation {
    private static let forbiddenInDomain = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "@/"))
    private static let forbiddenInLocal = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"&'/:<>@"))

    static func validate(local: String?, domain: String) -> (local: String?, domain: String)? {
        var normalisedDomain = domain.lowercased()
        if normalisedDomain.hasSuffix(".") {
            normalisedDomain.removeLast()
        }
        if normalisedDomain.isEmpty || normalisedDomain.utf8.count > 1023 {
            return nil
        }
        if normalisedDomain.rangeOfCharacter(from: forbiddenInDomain) != nil {
            return nil
        }
        var normalisedLocal: String? = nil
        if let local = local {
            if local.isEmpty || local.utf8.count > 1023 {
                return nil
            }
            if local.rangeOfCharacter(from: forbiddenInLocal) != nil {
                return nil
            }
            normalisedLocal = local.lowercased()
        }
        return (normalisedLocal, normalisedDomain)
    }
}
