import Foundation

// Named XMPPElement (not XMLElement) so it never clashes with Foundation.XMLElement on macOS.

/// A parsed (or to-be-serialised) XML element.
///
/// Names are kept exactly as written, including any prefix (`stream:features`),
/// and namespace declarations are ordinary attributes (`xmlns`). All text
/// content of the element (not of its children) is concatenated into `text`.
public struct XMPPElement: Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var attributes: [String: String]
    public var children: [XMPPElement]
    public var text: String

    public init(name: String, attributes: [String: String] = [:], children: [XMPPElement] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    /// The name without its prefix (`features` for `stream:features`).
    public var localName: String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    /// The value of the `xmlns` attribute, if any.
    public var xmlns: String? {
        return attributes["xmlns"]
    }

    public func attribute(_ name: String) -> String? {
        return attributes[name]
    }

    /// The first child with this (qualified) name.
    public func child(named name: String) -> XMPPElement? {
        return children.first(where: { $0.name == name })
    }

    /// The first child with this name and `xmlns` attribute.
    public func child(named name: String, xmlns: String) -> XMPPElement? {
        return children.first(where: { $0.name == name && $0.attributes["xmlns"] == xmlns })
    }

    /// All children with this (qualified) name.
    public func children(named name: String) -> [XMPPElement] {
        return children.filter { $0.name == name }
    }

    /// Serialises the element. Text and attribute values are escaped; the
    /// `xmlns` attribute is written first and the rest in sorted order so the
    /// output is deterministic.
    public var xmlString: String {
        var output = ""
        write(to: &output)
        return output
    }

    public var description: String {
        return xmlString
    }

    private func write(to output: inout String) {
        output += "<"
        output += name
        if let namespace = attributes["xmlns"] {
            output += " xmlns='"
            output += XMLEscaping.escapeAttribute(namespace)
            output += "'"
        }
        for key in attributes.keys.sorted() where key != "xmlns" {
            output += " "
            output += key
            output += "='"
            output += XMLEscaping.escapeAttribute(attributes[key] ?? "")
            output += "'"
        }
        if children.isEmpty && text.isEmpty {
            output += "/>"
            return
        }
        output += ">"
        if !text.isEmpty {
            output += XMLEscaping.escapeText(text)
        }
        for child in children {
            child.write(to: &output)
        }
        output += "</"
        output += name
        output += ">"
    }
}

/// Escaping helpers for building XML by hand.
public enum XMLEscaping {
    /// Escapes `&`, `<` and `>` and drops characters that are not allowed in XML 1.0.
    public static func escapeText(_ string: String) -> String {
        return escape(string, forAttribute: false)
    }

    /// Escapes `&`, `<`, `>`, `'` and `"` (plus tab/newline) for use inside a quoted attribute value.
    public static func escapeAttribute(_ string: String) -> String {
        return escape(string, forAttribute: true)
    }

    private static func escape(_ string: String, forAttribute: Bool) -> String {
        var output = ""
        output.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x26:
                output += "&amp;"
            case 0x3C:
                output += "&lt;"
            case 0x3E:
                output += "&gt;"
            case 0x22:
                if forAttribute { output += "&quot;" } else { output.unicodeScalars.append(scalar) }
            case 0x27:
                if forAttribute { output += "&apos;" } else { output.unicodeScalars.append(scalar) }
            case 0x09:
                if forAttribute { output += "&#9;" } else { output.unicodeScalars.append(scalar) }
            case 0x0A:
                if forAttribute { output += "&#10;" } else { output.unicodeScalars.append(scalar) }
            case 0x0D:
                if forAttribute { output += "&#13;" } else { output.unicodeScalars.append(scalar) }
            case 0x00...0x1F, 0xFFFE, 0xFFFF:
                // Not allowed in XML 1.0; a server would close the stream.
                continue
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
