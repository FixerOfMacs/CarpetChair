import Foundation

/// One smiley: an image and the text triggers that produce it.
public struct Smiley: Equatable, Sendable {
    /// The image file name as stored in the table, e.g. `"smile.tif"` or `"Star Eyes.tif"`.
    public let fileName: String
    /// `fileName` without its image extension, e.g. `"smile"` (asset-catalog style).
    public let imageName: String
    /// Display name, e.g. `"Smile"` (falls back to `imageName`).
    public let name: String
    /// Text triggers, e.g. `[":-)", ":)"]`. Unique across a `SmileyTable`.
    public let triggers: [String]

    public init(fileName: String, name: String? = nil, triggers: [String]) {
        self.fileName = fileName
        let stripped = Smiley.stripImageExtension(fileName)
        self.imageName = stripped
        if let name = name, !name.isEmpty {
            self.name = name
        } else {
            self.name = stripped
        }
        self.triggers = triggers
    }

    static func stripImageExtension(_ fileName: String) -> String {
        let lowercased = fileName.lowercased()
        for suffix in [".tiff", ".tif", ".png", ".pdf", ".jpg", ".jpeg", ".gif"] {
            if lowercased.hasSuffix(suffix) {
                return String(fileName.dropLast(suffix.count))
            }
        }
        return fileName
    }
}

public enum SmileyTableError: Error, Equatable {
    case invalidFormat(String)
}

/// The contents of a `SmileyTable.plist`.
///
/// iChat's format (primary): root dict with `SmileysPerRow` (Int) and
/// `SmileyList`, an array of dicts with `ASCII` ([String]), `Filename`
/// (String) and `SmileyName` (String). The older `ImageName` /
/// `TextTriggers` / `Description` keys are accepted as a fallback.
public struct SmileyTable: Equatable, Sendable {
    /// Picker layout hint from the plist (10 when absent).
    public let smileysPerRow: Int
    /// Every entry in file order. A trigger that already belongs to an earlier
    /// entry is removed from later ones, so triggers are unique.
    public let entries: [Smiley]

    public init(smileysPerRow: Int = 10, entries: [Smiley]) {
        self.smileysPerRow = smileysPerRow
        var seen = Set<String>()
        var unique: [Smiley] = []
        for entry in entries {
            var triggers: [String] = []
            for trigger in entry.triggers where !trigger.isEmpty && !seen.contains(trigger) {
                seen.insert(trigger)
                triggers.append(trigger)
            }
            unique.append(Smiley(fileName: entry.fileName, name: entry.name, triggers: triggers))
        }
        self.entries = unique
    }

    public init(plistData: Data) throws {
        let object = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        guard let root = object as? [String: Any] else {
            throw SmileyTableError.invalidFormat("the root is not a dictionary")
        }
        guard let list = root["SmileyList"] as? [[String: Any]] else {
            throw SmileyTableError.invalidFormat("missing SmileyList array")
        }
        var perRow = 10
        if let number = root["SmileysPerRow"] as? Int, number > 0 {
            perRow = number
        } else if let text = root["SmileysPerRow"] as? String, let number = Int(text), number > 0 {
            perRow = number
        }
        var parsed: [Smiley] = []
        for entry in list {
            let fileName = (entry["Filename"] as? String) ?? (entry["ImageName"] as? String)
            let triggers = (entry["ASCII"] as? [String]) ?? (entry["TextTriggers"] as? [String])
            let name = (entry["SmileyName"] as? String) ?? (entry["Description"] as? String)
            guard let file = fileName, !file.isEmpty, let texts = triggers else { continue }
            parsed.append(Smiley(fileName: file, name: name, triggers: texts))
        }
        self.init(smileysPerRow: perRow, entries: parsed)
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(plistData: data)
    }

    /// Entries for a picker: file order, one per `fileName` (the first entry wins).
    public var pickerSmileys: [Smiley] {
        var seen = Set<String>()
        var result: [Smiley] = []
        for entry in entries where !seen.contains(entry.fileName) {
            seen.insert(entry.fileName)
            result.append(entry)
        }
        return result
    }
}

/// Splits message text into plain text and smileys.
///
/// Rules: the longest trigger wins; a trigger only matches at the start of the
/// text or after whitespace, and only when followed by the end of the text,
/// whitespace or one of `.,!?;`; whitespace-separated tokens that contain
/// `://` or start with `www.` never contain smileys.
public struct SmileyParser: Sendable {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case smiley(imageName: String, trigger: String)
    }

    private struct Trigger: Sendable {
        let characters: [Character]
        let text: String
        let smileyIndex: Int
    }

    public let smileys: [Smiley]
    private let triggersByFirstCharacter: [Character: [Trigger]]

    private static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";"]

    /// Builds a parser from `(imageName, triggers)` pairs. The image name is used as given.
    public init(_ table: [(imageName: String, triggers: [String])]) {
        var list: [Smiley] = []
        for row in table {
            list.append(Smiley(fileName: row.imageName, triggers: row.triggers))
        }
        self.init(smileys: list)
    }

    /// Builds a parser from smileys. If a trigger appears twice, the first smiley wins.
    public init(smileys: [Smiley]) {
        self.smileys = smileys
        var seen = Set<String>()
        var index: [Character: [Trigger]] = [:]
        for (position, smiley) in smileys.enumerated() {
            for trigger in smiley.triggers where !trigger.isEmpty && !seen.contains(trigger) {
                seen.insert(trigger)
                let characters = Array(trigger)
                let entry = Trigger(characters: characters, text: trigger, smileyIndex: position)
                index[characters[0], default: []].append(entry)
            }
        }
        // Longest first, so ">:)" beats ":)" and "O:-)" beats "O:)".
        self.triggersByFirstCharacter = index.mapValues { (list: [Trigger]) -> [Trigger] in
            return list.sorted { $0.characters.count > $1.characters.count }
        }
    }

    public init(table: SmileyTable) {
        self.init(smileys: table.entries)
    }

    /// The smiley a trigger belongs to (e.g. to get its `fileName`).
    public func smiley(forTrigger trigger: String) -> Smiley? {
        guard let first = trigger.first, let candidates = triggersByFirstCharacter[first] else { return nil }
        for candidate in candidates where candidate.text == trigger {
            return smileys[candidate.smileyIndex]
        }
        return nil
    }

    public func segments(for text: String) -> [Segment] {
        let characters = Array(text)
        if characters.isEmpty {
            return []
        }
        let insideURL = SmileyParser.urlMask(characters)
        var segments: [Segment] = []
        var pending = ""
        var position = 0
        while position < characters.count {
            let atWordStart = position == 0 || characters[position - 1].isWhitespace
            if atWordStart && !insideURL[position],
               let candidates = triggersByFirstCharacter[characters[position]],
               let trigger = match(candidates, in: characters, at: position) {
                if !pending.isEmpty {
                    segments.append(.text(pending))
                    pending = ""
                }
                let smiley = smileys[trigger.smileyIndex]
                segments.append(.smiley(imageName: smiley.imageName, trigger: trigger.text))
                position += trigger.characters.count
                continue
            }
            pending.append(characters[position])
            position += 1
        }
        if !pending.isEmpty {
            segments.append(.text(pending))
        }
        return segments
    }

    private func match(_ candidates: [Trigger], in characters: [Character], at start: Int) -> Trigger? {
        for candidate in candidates {
            let end = start + candidate.characters.count
            if end > characters.count {
                continue
            }
            var matches = true
            var offset = 0
            while offset < candidate.characters.count {
                if characters[start + offset] != candidate.characters[offset] {
                    matches = false
                    break
                }
                offset += 1
            }
            if !matches {
                continue
            }
            if end == characters.count || SmileyParser.isTrailingBoundary(characters[end]) {
                return candidate
            }
        }
        return nil
    }

    private static func isTrailingBoundary(_ character: Character) -> Bool {
        return character.isWhitespace || trailingPunctuation.contains(character)
    }

    /// Marks every character of a whitespace-separated token that looks like a URL.
    private static func urlMask(_ characters: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: characters.count)
        var start = 0
        while start < characters.count {
            if characters[start].isWhitespace {
                start += 1
                continue
            }
            var end = start
            while end < characters.count && !characters[end].isWhitespace {
                end += 1
            }
            let token = String(characters[start..<end])
            if token.contains("://") || token.lowercased().hasPrefix("www.") {
                var index = start
                while index < end {
                    mask[index] = true
                    index += 1
                }
            }
            start = end
        }
        return mask
    }
}
