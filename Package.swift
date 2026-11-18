// swift-tools-version:5.9
import PackageDescription

// BuddyCore is plain Foundation (no AppKit) so its logic can be unit tested.
// The app target is macOS-only.
var products: [Product] = [
    .library(name: "BuddyCore", targets: ["BuddyCore"]),
]

var targets: [Target] = [
    .target(
        name: "BuddyCore",
        path: "Sources/BuddyCore"
    ),
    .testTarget(
        name: "BuddyCoreTests",
        dependencies: ["BuddyCore"],
        path: "Tests/BuddyCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "Buddy", targets: ["Buddy"]))
targets.append(
    .executableTarget(
        name: "Buddy",
        dependencies: ["BuddyCore"],
        path: "Sources/Buddy",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Speech"),
            .linkedFramework("Carbon"),
        ]
    )
)
#endif

let package = Package(
    name: "Buddy",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
