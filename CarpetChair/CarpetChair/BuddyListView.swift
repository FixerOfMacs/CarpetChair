import SwiftUI
import XMPPCore

/// The buddy list: buddy requests at the top, then buddies (online first), then chats with
/// people who aren't buddies yet.
struct BuddyListView: View {
    @EnvironmentObject private var client: XMPPClient
    @Binding var selection: BareJID?
    @Binding var showingAddBuddy: Bool
    @State private var buddyToRemove: Buddy?

    private var sortedBuddies: [Buddy] {
        client.roster.sorted { first, second in
            if rank(first.presence) != rank(second.presence) {
                return rank(first.presence) < rank(second.presence)
            }
            return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
        }
    }

    /// People who messaged us (or whom we messaged) but aren't on the buddy list.
    private var otherChats: [BareJID] {
        let buddyIDs = Set(client.roster.map { $0.id })
        return client.conversations.keys.filter { !buddyIDs.contains($0) }.sorted()
    }

    var body: some View {
        List(selection: $selection) {
            if !client.pendingSubscriptionRequests.isEmpty {
                Section("Buddy Requests") {
                    ForEach(client.pendingSubscriptionRequests, id: \.self) { requester in
                        BuddyRequestRow(requester: requester)
                    }
                }
            }

            Section("Buddies") {
                if client.roster.isEmpty {
                    Text("No buddies yet. Tap + to add one.")
                        .foregroundColor(.secondary)
                }
                ForEach(sortedBuddies) { buddy in
                    BuddyRow(buddy: buddy)
                        .tag(buddy.id as BareJID?)
                        .swipeActions {
                            Button(role: .destructive) {
                                buddyToRemove = buddy
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                buddyToRemove = buddy
                            } label: {
                                Label("Remove Buddy", systemImage: "trash")
                            }
                        }
                }
            }

            if !otherChats.isEmpty {
                Section("Other Chats") {
                    ForEach(otherChats, id: \.self) { contact in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 34))
                                .foregroundColor(.secondary)
                            Text(contact.description)
                                .font(.headline)
                        }
                        .tag(contact as BareJID?)
                    }
                }
            }
        }
        .navigationTitle("Buddies")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                MyStatusMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddBuddy = true
                } label: {
                    Label("Add Buddy", systemImage: "plus")
                }
            }
        }
        .confirmationDialog("Remove this buddy?",
                            isPresented: Binding(get: { buddyToRemove != nil },
                                                 set: { if !$0 { buddyToRemove = nil } }),
                            titleVisibility: .visible,
                            presenting: buddyToRemove) { buddy in
            Button("Remove \(buddy.displayName)", role: .destructive) {
                if selection == buddy.id {
                    selection = nil
                }
                client.removeBuddy(jid: buddy.jid)
                buddyToRemove = nil
            }
        } message: { buddy in
            Text("\(buddy.jid.bareString) will be taken off your buddy list, and you'll stop seeing when they're online.")
        }
    }

    private func rank(_ presence: PresenceShow) -> Int {
        switch presence {
        case .available: return 0
        case .away: return 1
        case .offline: return 2
        }
    }
}

struct BuddyRow: View {
    let buddy: Buddy

    private var subtitle: String {
        if buddy.isAwaitingAuthorization {
            return "Waiting for them to accept"
        }
        if let status = buddy.statusText, !status.isEmpty {
            return status
        }
        return buddy.jid.bareString
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 34))

                Circle()
                    .fill(statusColor(for: buddy.presence))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(buddy.displayName).font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(buddy.presence == .offline ? 0.6 : 1)
    }
}

/// Someone asked to add us as a buddy.
struct BuddyRequestRow: View {
    @EnvironmentObject private var client: XMPPClient
    let requester: JID

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(requester.bareString).font(.headline)
                Text("wants to be your buddy")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Accept") {
                client.acceptSubscription(from: requester)
            }
            .buttonStyle(.borderedProminent)
            Button("Decline") {
                client.declineSubscription(from: requester)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Our own status: Available / Away, and Sign Out.
struct MyStatusMenu: View {
    @EnvironmentObject private var client: XMPPClient

    var body: some View {
        Menu {
            Button {
                client.setPresence(.available)
            } label: {
                Label("Available", systemImage: "circle.fill")
            }
            Button {
                client.setPresence(.away)
            } label: {
                Label("Away", systemImage: "moon.fill")
            }
            Divider()
            Button(role: .destructive) {
                client.logout()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: client.ownPresence))
                    .frame(width: 10, height: 10)
                Text(statusLabel(for: client.ownPresence))
                    .font(.subheadline)
            }
        }
    }
}
