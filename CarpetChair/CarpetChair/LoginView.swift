import SwiftUI
import XMPPCore

/// Sign in with a Jabber (XMPP) account, the same kind of account iChat used.
struct LoginView: View {
    @EnvironmentObject private var client: XMPPClient
    @AppStorage("jabberID") private var jabberID = ""
    @AppStorage("serverHost") private var serverHost = ""
    @AppStorage("serverPort") private var serverPort = ""
    @AppStorage("rememberPassword") private var rememberPassword = true
    @State private var password = ""
    @State private var showServerSettings = false

    /// Only try the automatic sign-in once per launch, so a wrong saved password
    /// doesn't loop.
    private static var triedAutomaticSignIn = false

    private let accentColor = Color.blue

    private var isBusy: Bool {
        client.connectionState == .connecting || client.connectionState == .authenticating
    }

    private var canSignIn: Bool {
        !isBusy && !trimmed(jabberID).isEmpty && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AppIconView()
                    .padding(.top, 40)

                Text("Sign in to Jabber")
                    .font(.title).bold()

                Text("Use any Jabber (XMPP) account, the same kind iChat used.\nFor example: yourname@xmpp.jp")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Jabber ID (name@server.com)", text: $jabberID)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)

                    Toggle("Remember my password", isOn: $rememberPassword)
                        .font(.subheadline)

                    DisclosureGroup("Server settings (optional)", isExpanded: $showServerSettings) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Server (empty = find it automatically)", text: $serverHost)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Port (empty = 5222)", text: $serverPort)
                                .keyboardType(.numberPad)
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .padding(.horizontal, 40)

                if let error = client.connectionState.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 40)
                }

                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().tint(.white)
                        }
                        Text(isBusy ? "Signing In…" : "Sign In")
                    }
                    .padding(.horizontal, 24)
                }
                .padding()
                .background(canSignIn || isBusy ? accentColor : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
                .disabled(!canSignIn)
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if password.isEmpty, let saved = Keychain.password(for: trimmed(jabberID)) {
                password = saved
            }
            if !LoginView.triedAutomaticSignIn {
                LoginView.triedAutomaticSignIn = true
                if rememberPassword && canSignIn {
                    signIn()
                }
            }
        }
    }

    private func signIn() {
        guard canSignIn else { return }
        let jid = trimmed(jabberID)
        jabberID = jid
        if rememberPassword {
            Keychain.savePassword(password, for: jid)
        } else {
            Keychain.deletePassword(for: jid)
        }
        let host = trimmed(serverHost)
        client.login(jid: jid,
                     password: password,
                     hostOverride: host.isEmpty ? nil : host,
                     portOverride: Int(trimmed(serverPort)))
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Signs in again with the saved Jabber ID and Keychain password, if there are any.
    /// Used when the app comes back from the background after iOS dropped the connection.
    static func signInWithSavedPassword(client: XMPPClient) {
        let defaults = UserDefaults.standard
        let jid = (defaults.string(forKey: "jabberID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard defaults.object(forKey: "rememberPassword") as? Bool ?? true,
              !jid.isEmpty,
              let password = Keychain.password(for: jid) else { return }
        let host = (defaults.string(forKey: "serverHost") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int((defaults.string(forKey: "serverPort") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        client.login(jid: jid, password: password, hostOverride: host.isEmpty ? nil : host, portOverride: port)
    }
}
