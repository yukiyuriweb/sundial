// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sundial",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Sundial",
            path: "Sources/Sundial",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
