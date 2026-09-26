import SwiftUI
import XMPPCore

/// Shows the sign-in screen until the Jabber connection is online, then the buddy list and chats.
struct ContentView: View {
    @EnvironmentObject private var client: XMPPClient
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if client.connectionState == .online {
                MainView()
            } else {
                LoginView()
            }
        }
        // iOS drops the connection while the app is in the background. When it comes back,
        // sign in again with the remembered password instead of leaving the user at the login screen.
        .onChange(of: scenePhase) {
            if scenePhase == .active, client.connectionState.errorMessage != nil {
                LoginView.signInWithSavedPassword(client: client)
            }
        }
    }
}

/// The signed-in screen: buddies on the left, the chat on the right (stacked on iPhone).
struct MainView: View {
    @EnvironmentObject private var client: XMPPClient
    @State private var selection: BareJID?
    @State private var showingAddBuddy = false

    var body: some View {
        NavigationSplitView {
            BuddyListView(selection: $selection, showingAddBuddy: $showingAddBuddy)
        } detail: {
            if let partner = selection {
                ChatView(partner: partner.jid)
                    .id(partner)
            } else {
                SmileyReferenceView()
            }
        }
        .sheet(isPresented: $showingAddBuddy) {
            AddBuddyView()
                .environmentObject(client)
        }
    }
}

/// Green = available, yellow = away, red = offline, as in the original CarpetChair.
func statusColor(for presence: PresenceShow) -> Color {
    switch presence {
    case .available: return .green
    case .away: return .yellow
    case .offline: return .red
    }
}

func statusLabel(for presence: PresenceShow) -> String {
    switch presence {
    case .available: return "Available"
    case .away: return "Away"
    case .offline: return "Offline"
    }
}

/// Shown when no chat is open: every smiley, what it's called and what to type for it.
struct SmileyReferenceView: View {
    @ObservedObject private var library = iChatSmileyLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("iChat Emoticon Reference Index")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color(.systemGroupedBackground))

            List {
                HStack {
                    Text("ICON").font(.caption).fontWeight(.bold).frame(width: 50, alignment: .center)
                    Text("NAME").font(.caption).fontWeight(.bold).frame(width: 150, alignment: .leading)
                    Text("TYPE").font(.caption).fontWeight(.bold).frame(alignment: .leading)
                }
                .foregroundColor(.secondary)
                .listRowBackground(Color.clear)

                ForEach(library.activeSmileys) { smiley in
                    HStack(spacing: 12) {
                        SmileyImage(smiley: smiley, size: 32)
                            .frame(width: 50)

                        Text(smiley.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 150, alignment: .leading)

                        Text(smiley.triggers.joined(separator: "  "))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(PlainListStyle())

            Text("Pick a buddy to start chatting, or tap + to add one.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
    }
}
