// swift-tools-version:5.9
import PackageDescription

// Pure, platform-free half of the Apple Watch port (SPEC §14): everything here builds and tests on
// macOS with `swift test`, and the watchOS app target (../HermesWatch) links it unchanged.
let package = Package(
    name: "HermesCore",
    platforms: [.macOS(.v13), .watchOS(.v10), .iOS(.v16)],
    products: [.library(name: "HermesCore", targets: ["HermesCore"])],
    targets: [
        .target(name: "HermesCore"),
        .testTarget(name: "HermesCoreTests", dependencies: ["HermesCore"]),
    ]
)
