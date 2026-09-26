import SwiftUI
import UIKit
import XMPPCore

// 1. Core Data Model
struct iChatConfigSmiley: Identifiable, Hashable {
    let name: String
    /// The image file in the app, e.g. "smile.tif".
    let fileName: String
    let triggers: [String]

    var id: String { fileName }
    /// What the picker types for this smiley.
    var trigger: String { triggers.first ?? "" }
}

// 2. Master Data Library: loads SmileyTable.plist from the app, in iChat's own format
//    (SmileyList → ASCII / Filename / SmileyName, plus SmileysPerRow).
final class iChatSmileyLibrary: ObservableObject {
    static let shared = iChatSmileyLibrary()

    /// One entry per image, in the table's order, for the picker and the reference list.
    @Published private(set) var activeSmileys: [iChatConfigSmiley] = []
    private(set) var smileysPerRow = 10
    private var parser = SmileyParser(smileys: [])
    private var imageCache: [String: UIImage] = [:]

    init() {
        loadSmileyTable()
    }

    private func loadSmileyTable() {
        guard let url = Bundle.main.url(forResource: "SmileyTable", withExtension: "plist"),
              let table = try? SmileyTable(contentsOf: url) else { return }
        parser = SmileyParser(table: table)
        smileysPerRow = table.smileysPerRow
        activeSmileys = table.pickerSmileys.map {
            iChatConfigSmiley(name: $0.name, fileName: $0.fileName, triggers: $0.triggers)
        }
    }

    /// Splits a message into text and smileys. The longest trigger wins (">:)" is Naughty,
    /// not ">" + Smile), and web links are left alone ("http://" never becomes Undecided).
    func segments(for text: String) -> [SmileyParser.Segment] {
        parser.segments(for: text)
    }

    func fileName(forTrigger trigger: String) -> String? {
        parser.smiley(forTrigger: trigger)?.fileName
    }

    /// The iChat .tif files are copied into the app unchanged, so asking for the full file
    /// name ("smile.tif") loads them directly. Nil for smileys whose image isn't in the app.
    func image(named fileName: String) -> UIImage? {
        if let cached = imageCache[fileName] {
            return cached
        }
        guard let image = UIImage(named: fileName) else { return nil }
        imageCache[fileName] = image
        return image
    }
}

/// A smiley's image, or its trigger text when the image isn't in the app.
struct SmileyImage: View {
    let smiley: iChatConfigSmiley
    let size: CGFloat

    var body: some View {
        if let uiImage = iChatSmileyLibrary.shared.image(named: smiley.fileName) {
            Image(uiImage: uiImage)
                .resizable()
                .interpolation(.none) // Sharp retro rendering
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Text("[\(smiley.trigger)]")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
    }
}

// 3. THE PICKER PANEL: The Grid UI displaying all the smileys to click!
struct iChatSmileyPickerPanel: View {
    @Binding var chatInputText: String
    @ObservedObject var library = iChatSmileyLibrary.shared

    // Layout matrix for a clean, square-grid panel view
    let columns = [
        GridItem(.adaptive(minimum: 45, maximum: 55), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(library.activeSmileys) { smiley in
                        Button(action: {
                            // Append the trigger text; it's sent as text, so iChat shows the same smiley.
                            if chatInputText.isEmpty || chatInputText.hasSuffix(" ") {
                                chatInputText += "\(smiley.trigger) "
                            } else {
                                chatInputText += " \(smiley.trigger) "
                            }
                        }) {
                            SmileyImage(smiley: smiley, size: 32)
                                .frame(width: 45, height: 45)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        .accessibilityLabel(smiley.name)
                    }
                }
                .padding(.all, 12)
            }
            .frame(height: 200) // Original popup drawer sizing proportions
            .background(Color(UIColor.systemBackground))
        }
    }
}

// 4. Custom Inline Chat Message Text Display View: text with the smileys drawn in.
struct iChatParsedMessageView: View {
    let text: String
    @ObservedObject var library = iChatSmileyLibrary.shared

    var body: some View {
        library.segments(for: text).reduce(Text(verbatim: "")) { result, segment in
            switch segment {
            case .text(let plain):
                return result + Text(verbatim: plain)
            case .smiley(_, let trigger):
                guard let fileName = library.fileName(forTrigger: trigger),
                      let image = library.image(named: fileName) else {
                    return result + Text(verbatim: trigger)
                }
                return result + Text(Image(uiImage: image).renderingMode(.original)).baselineOffset(-4)
            }
        }
        .font(.system(size: 15))
    }
}
