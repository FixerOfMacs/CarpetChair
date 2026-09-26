// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XMPPCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "XMPPCore", targets: ["XMPPCore"]),
    ],
    targets: [
        .target(
            name: "XMPPCore",
            path: "Sources/XMPPCore"
        ),
    ]
)
