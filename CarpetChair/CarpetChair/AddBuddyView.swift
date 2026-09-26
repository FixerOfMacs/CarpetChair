import SwiftUI
import XMPPCore

/// Adds a buddy: puts them on the buddy list and sends them a buddy request.
struct AddBuddyView: View {
    @EnvironmentObject private var client: XMPPClient
    @Environment(\.dismiss) private var dismiss
    @State private var jabberID = ""
    @State private var nickname = ""

    private var buddyJID: JID? {
        guard let jid = JID(jabberID.trimmingCharacters(in: .whitespacesAndNewlines)),
              jid.local != nil else { return nil }
        return jid.bareJID
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Jabber ID (friend@server.com)", text: $jabberID)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nickname (optional)", text: $nickname)
                } footer: {
                    Text("They'll get a buddy request. Once they accept, you'll see when they're online.")
                }
            }
            .navigationTitle("Add Buddy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let jid = buddyJID {
                            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            client.addBuddy(jid: jid, name: name.isEmpty ? nil : name)
                        }
                        dismiss()
                    }
                    .disabled(buddyJID == nil)
                }
            }
        }
    }
}
