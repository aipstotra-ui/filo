// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    platforms: [
        // FoundationModels (Apple's built-in on-device model) requires macOS 26.
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "FileOrganizer",
            path: "Sources/FileOrganizer",
            swiftSettings: [
                // Existing Watcher/UI code predates strict concurrency; kept in
                // Swift 5 language mode for now. swift-builder decides when to
                // flip this to .v6 (engineering-rules.md wants strict checking
                // from M3, but migrating Watcher/UI is its call, not RED-phase's).
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "FileOrganizerTests",
            dependencies: ["FileOrganizer"],
            path: "Tests/FileOrganizerTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
