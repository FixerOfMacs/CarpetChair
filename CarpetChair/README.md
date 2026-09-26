# CarpetChair

An iChat-style Jabber (XMPP) chat app for iPad and iPhone (iOS 17+), with iChat's original smileys.

- **Log in** with any Jabber/XMPP account, the same kind of account iChat used for Jabber
  (for example `you@xmpp.jp`). The password is kept in the iPad's Keychain if you tick
  "Remember me".
- **Buddies:** your buddy list comes from the server. Add buddies with **+**, and accept or
  decline other people's buddy requests. Green means available, yellow away, red offline.
- **Smileys:** type `:-)`, `;-)`, `<3` and the rest, or pick one from the smiley panel. They
  show as the iChat `.tif` images and go out as plain text, so iChat and other Jabber apps
  see the same smileys. `CarpetChair/Smileys/SmileyTable.plist` lists them all.

## Getting the .ipa

Every push runs **Actions → Compile iOS App (.ipa)**. When it finishes, open the run and
download the `CarpetChair-ipa` artifact (a zip containing `CarpetChair.ipa`).

The .ipa is **unsigned**: only your own Apple ID can sign an app for your iPad. Install it
with **Sideloadly** or **AltStore**, which sign it with your Apple ID as they install it.
(With a free Apple ID the app has to be re-installed every 7 days.)

## Layout

| Path | What it is |
|---|---|
| `CarpetChair/` | The app: SwiftUI screens, the smiley engine, Keychain storage, the icon |
| `CarpetChair/Smileys/` | iChat's smiley images (`.tif`) and `SmileyTable.plist` |
| `Packages/XMPPCore/` | The Jabber engine: connection, TLS, login, buddy list, messages. Has its own tests |
| `project.yml` | The Xcode project, in XcodeGen form (`xcodegen generate` creates `CarpetChair.xcodeproj`) |
| `.github/workflows/compile-ios.yml` | Runs the tests, builds `CarpetChair.app`, and packages the .ipa |

## Building on a Mac

```sh
brew install xcodegen
xcodegen generate
open CarpetChair.xcodeproj
```

Pick your iPad as the destination and press Run; Xcode signs it with your Apple ID.
