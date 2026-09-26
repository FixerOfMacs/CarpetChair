import Foundation

/// Something the stream parser recognised.
public enum XMLStreamEvent: Equatable, Sendable {
    /// The `<stream:stream …>` header (children empty). Sent again after a
    /// stream restart.
    case streamOpened(XMPPElement)
    /// A complete depth-1 element: a stanza, `stream:features`, a SASL element…
    case element(XMPPElement)
    /// `</stream:stream>` arrived.
    case streamClosed
}

public struct XMLStreamParserError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return "Malformed XML: " + message
    }
}

/// An incremental, byte-based parser for an XMPP stream: one XML document that
/// stays open for the whole session.
///
/// Feed it data in chunks of any size (a chunk may end in the middle of a tag,
/// an entity or a multi-byte UTF-8 character); bytes are buffered and only
/// complete tokens are decoded. Each depth-1 child of the stream root is
/// emitted as a complete tree once its end tag arrives.
public final class XMLStreamParser {
    /// Largest incomplete token (a tag or a text run) the parser will buffer.
    public var maximumTokenSize = 4 * 1024 * 1024
    /// Deepest nesting accepted inside a stanza.
    public var maximumDepth = 128

    public private(set) var isStreamOpen = false

    private var buffer: [UInt8] = []
    private var stack: [XMPPElement] = []

    public init() {}

    /// Forgets all state. Call when a new stream starts (after STARTTLS or SASL).
    public func reset() {
        buffer.removeAll()
        stack.removeAll()
        isStreamOpen = false
    }

    /// Adds bytes and returns every event they completed.
    public func feed(_ data: Data) throws -> [XMLStreamEvent] {
        buffer.append(contentsOf: data)
        var events: [XMLStreamEvent] = []
        var position = 0
        defer {
            if position > 0 {
                if position >= buffer.count {
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    buffer.removeFirst(position)
                }
            }
        }

        scan: while position < buffer.count {
            if buffer[position] != Byte.lessThan {
                // Character data runs up to the next '<'.
                guard let next = indexOf(Byte.lessThan, from: position) else {
                    if stack.isEmpty {
                        // Whitespace between stanzas (e.g. keepalives): drop it.
                        position = buffer.count
                    }
                    break scan
                }
                if !stack.isEmpty {
                    let text = XMLStreamParser.decodeCharacters(buffer[position..<next])
                    stack[stack.count - 1].text += text
                }
                position = next
                continue scan
            }

            guard position + 1 < buffer.count else { break scan }
            let second = buffer[position + 1]

            if second == Byte.question {
                // <?xml …?> or another processing instruction: skip it.
                guard let end = find(Byte.processingInstructionEnd, from: position + 2) else { break scan }
                position = end + 2
            } else if second == Byte.exclamation {
                let comment = match(Byte.commentStart, at: position)
                let cdata = match(Byte.cdataStart, at: position)
                if comment == .full {
                    guard let end = find(Byte.commentEnd, from: position + 4) else { break scan }
                    position = end + 3
                } else if cdata == .full {
                    let start = position + Byte.cdataStart.count
                    guard let end = find(Byte.cdataEnd, from: start) else { break scan }
                    if !stack.isEmpty {
                        stack[stack.count - 1].text += String(decoding: buffer[start..<end], as: UTF8.self)
                    }
                    position = end + 3
                } else if comment == .partial || cdata == .partial {
                    break scan
                } else {
                    // <!DOCTYPE …> or similar: not allowed in XMPP, skip it.
                    guard let end = indexOf(Byte.greaterThan, from: position + 2) else { break scan }
                    position = end + 1
                }
            } else if second == Byte.slash {
                guard let end = indexOf(Byte.greaterThan, from: position + 2) else { break scan }
                let rawName = String(decoding: buffer[(position + 2)..<end], as: UTF8.self)
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                try handleEndTag(name, events: &events)
                position = end + 1
            } else {
                guard let end = findTagEnd(from: position + 1) else { break scan }
                try handleStartTag(buffer[(position + 1)..<end], events: &events)
                position = end + 1
            }
        }

        if buffer.count - position > maximumTokenSize {
            throw XMLStreamParserError("token larger than \(maximumTokenSize) bytes")
        }
        return events
    }

    // MARK: - Tags

    private func handleStartTag(_ bytes: ArraySlice<UInt8>, events: inout [XMLStreamEvent]) throws {
        let tag = try XMLStreamParser.parseStartTag(bytes)
        let element = XMPPElement(name: tag.name, attributes: tag.attributes)

        if stack.isEmpty && (!isStreamOpen || XMLStreamParser.isStreamHeader(tag.name)) {
            // The stream root (or a restarted stream).
            isStreamOpen = true
            events.append(.streamOpened(element))
            if tag.selfClosing {
                isStreamOpen = false
                events.append(.streamClosed)
            }
            return
        }

        if tag.selfClosing {
            finish(element, events: &events)
        } else {
            if stack.count >= maximumDepth {
                throw XMLStreamParserError("elements nested too deeply")
            }
            stack.append(element)
        }
    }

    private func handleEndTag(_ name: String, events: inout [XMLStreamEvent]) throws {
        if let open = stack.popLast() {
            if open.name != name {
                throw XMLStreamParserError("expected </\(open.name)> but found </\(name)>")
            }
            finish(open, events: &events)
        } else if isStreamOpen {
            isStreamOpen = false
            events.append(.streamClosed)
        } else {
            throw XMLStreamParserError("unexpected </\(name)>")
        }
    }

    /// Attaches a completed element to its parent, or emits it at depth 1.
    private func finish(_ element: XMPPElement, events: inout [XMLStreamEvent]) {
        if stack.isEmpty {
            events.append(.element(element))
        } else {
            stack[stack.count - 1].children.append(element)
        }
    }

    private static func isStreamHeader(_ name: String) -> Bool {
        return name == "stream:stream" || name.hasSuffix(":stream")
    }

    struct StartTag {
        var name: String
        var attributes: [String: String]
        var selfClosing: Bool
    }

    /// Parses the bytes between `<` and `>` of a start tag.
    static func parseStartTag(_ bytes: ArraySlice<UInt8>) throws -> StartTag {
        var index = bytes.startIndex
        let end = bytes.endIndex

        let nameStart = index
        while index < end && !Byte.isSpace(bytes[index]) && bytes[index] != Byte.slash {
            index += 1
        }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
        if name.isEmpty {
            throw XMLStreamParserError("empty tag name")
        }

        var attributes: [String: String] = [:]
        var selfClosing = false
        while true {
            while index < end && Byte.isSpace(bytes[index]) {
                index += 1
            }
            if index >= end {
                break
            }
            if bytes[index] == Byte.slash {
                selfClosing = true
                index += 1
                while index < end && Byte.isSpace(bytes[index]) {
                    index += 1
                }
                if index != end {
                    throw XMLStreamParserError("unexpected characters after '/' in <\(name)>")
                }
                break
            }

            let attributeStart = index
            while index < end && bytes[index] != Byte.equals && !Byte.isSpace(bytes[index]) && bytes[index] != Byte.slash {
                index += 1
            }
            let attributeName = String(decoding: bytes[attributeStart..<index], as: UTF8.self)
            while index < end && Byte.isSpace(bytes[index]) {
                index += 1
            }
            if attributeName.isEmpty || index >= end || bytes[index] != Byte.equals {
                throw XMLStreamParserError("attribute without a value in <\(name)>")
            }
            index += 1
            while index < end && Byte.isSpace(bytes[index]) {
                index += 1
            }
            if index >= end || (bytes[index] != Byte.doubleQuote && bytes[index] != Byte.singleQuote) {
                throw XMLStreamParserError("unquoted attribute value in <\(name)>")
            }
            let quote = bytes[index]
            index += 1
            let valueStart = index
            while index < end && bytes[index] != quote {
                index += 1
            }
            if index >= end {
                throw XMLStreamParserError("unterminated attribute value in <\(name)>")
            }
            attributes[attributeName] = decodeCharacters(bytes[valueStart..<index])
            index += 1
        }

        return StartTag(name: name, attributes: attributes, selfClosing: selfClosing)
    }

    // MARK: - Entities

    /// Decodes UTF-8 and expands the five named entities plus `&#NN;` / `&#xNN;`.
    /// Unknown entities are left as literal text.
    static func decodeCharacters(_ bytes: ArraySlice<UInt8>) -> String {
        if !bytes.contains(Byte.ampersand) {
            return String(decoding: bytes, as: UTF8.self)
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == Byte.ampersand {
                let limit = min(index + 12, bytes.endIndex)
                var semicolon: Int? = nil
                var probe = index + 1
                while probe < limit {
                    if bytes[probe] == Byte.semicolon {
                        semicolon = probe
                        break
                    }
                    probe += 1
                }
                if let semicolonIndex = semicolon {
                    let entityName = String(decoding: bytes[(index + 1)..<semicolonIndex], as: UTF8.self)
                    if let scalar = entityScalar(entityName) {
                        output.append(contentsOf: Array(String(Character(scalar)).utf8))
                        index = semicolonIndex + 1
                        continue
                    }
                }
            }
            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func entityScalar(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "lt": return Unicode.Scalar(UInt8(0x3C))
        case "gt": return Unicode.Scalar(UInt8(0x3E))
        case "amp": return Unicode.Scalar(UInt8(0x26))
        case "quot": return Unicode.Scalar(UInt8(0x22))
        case "apos": return Unicode.Scalar(UInt8(0x27))
        default: break
        }
        guard name.hasPrefix("#"), name.count > 1 else { return nil }
        var digits = String(name.dropFirst())
        var radix = 10
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            digits = String(digits.dropFirst())
            radix = 16
        }
        guard !digits.isEmpty, let value = UInt32(digits, radix: radix) else { return nil }
        if value == 0 { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: - Byte scanning

    private enum MatchResult {
        case full
        case partial
        case mismatch
    }

    private func match(_ pattern: [UInt8], at start: Int) -> MatchResult {
        var offset = 0
        while offset < pattern.count {
            let index = start + offset
            if index >= buffer.count {
                return .partial
            }
            if buffer[index] != pattern[offset] {
                return .mismatch
            }
            offset += 1
        }
        return .full
    }

    private func indexOf(_ byte: UInt8, from start: Int) -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    private func find(_ pattern: [UInt8], from start: Int) -> Int? {
        if pattern.isEmpty {
            return start
        }
        var index = start
        while index + pattern.count <= buffer.count {
            var matched = true
            var offset = 0
            while offset < pattern.count {
                if buffer[index + offset] != pattern[offset] {
                    matched = false
                    break
                }
                offset += 1
            }
            if matched {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Finds the `>` that ends a start tag, ignoring any `>` inside quoted attribute values.
    private func findTagEnd(from start: Int) -> Int? {
        var quote: UInt8 = 0
        var index = start
        while index < buffer.count {
            let byte = buffer[index]
            if quote != 0 {
                if byte == quote {
                    quote = 0
                }
            } else if byte == Byte.doubleQuote || byte == Byte.singleQuote {
                quote = byte
            } else if byte == Byte.greaterThan {
                return index
            }
            index += 1
        }
        return nil
    }
}

enum Byte {
    static let lessThan: UInt8 = 0x3C
    static let greaterThan: UInt8 = 0x3E
    static let slash: UInt8 = 0x2F
    static let question: UInt8 = 0x3F
    static let exclamation: UInt8 = 0x21
    static let equals: UInt8 = 0x3D
    static let doubleQuote: UInt8 = 0x22
    static let singleQuote: UInt8 = 0x27
    static let ampersand: UInt8 = 0x26
    static let semicolon: UInt8 = 0x3B

    static let processingInstructionEnd: [UInt8] = Array("?>".utf8)
    static let commentStart: [UInt8] = Array("<!--".utf8)
    static let commentEnd: [UInt8] = Array("-->".utf8)
    static let cdataStart: [UInt8] = Array("<![CDATA[".utf8)
    static let cdataEnd: [UInt8] = Array("]]>".utf8)

    static func isSpace(_ byte: UInt8) -> Bool {
        return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
