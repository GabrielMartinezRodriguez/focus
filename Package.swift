// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "focus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "focus", path: "Sources/focus"),
        .executableTarget(name: "FocusBar", path: "Sources/FocusBar")
    ]
)
