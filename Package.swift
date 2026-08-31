// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMActivity",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LLMActivity",
            path: "Sources/LLMActivity",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
