import SwiftUI
import XMPPCore

/// One conversation: the messages (with iChat smileys drawn in), the smiley panel and the
/// message box.
struct ChatView: View {
    @EnvironmentObject private var client: XMPPClient
    let partner: JID
    @State private var draft = ""
    @State private var showingSmileys = false

    private let accentColor = Color.blue

    private var buddy: Buddy? {
        client.roster.first { $0.jid == partner }
    }

    private var partnerName: String {
        buddy?.displayName ?? partner.bareString
    }

    private var messages: [ChatMessage] {
        client.messages(with: partner)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(messages) { message in
                            ChatBubbleView(message: message,
                                           senderName: message.isFromMe ? "Me" : partnerName,
                                           accentColor: accentColor)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: messages.count) { scrollToBottom(proxy, animated: true) }
            }

            if showingSmileys {
                iChatSmileyPickerPanel(chatInputText: $draft)
            }

            inputBar
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(for: buddy?.presence ?? .offline))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(partnerName).font(.title).bold()
                Text(buddy?.statusText ?? statusLabel(for: buddy?.presence ?? .offline))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            Button {
                showingSmileys.toggle()
            } label: {
                if let smile = iChatSmileyLibrary.shared.image(named: "smile.tif") {
                    Image(uiImage: smile)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.title2)
                }
            }
            .accessibilityLabel("Smileys")

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(canSend ? accentColor : Color.gray)
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding()
        .background(Color(.systemBackground))
    }

    private func send() {
        guard canSend else { return }
        client.send(message: draft.trimmingCharacters(in: .whitespacesAndNewlines), to: partner)
        draft = ""
        showingSmileys = false
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    let senderName: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            Text("\(senderName) · \(message.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            iChatParsedMessageView(text: message.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isFromMe ? accentColor : Color(.secondarySystemGroupedBackground))
                .foregroundColor(message.isFromMe ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}
