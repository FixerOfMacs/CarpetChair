import SwiftUI
import XMPPCore

@main
struct CarpetChairApp: App {
    /// The one Jabber connection the whole app shares.
    @StateObject private var client = XMPPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
    }
}
