// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "YuhKeyScreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YuhKeyScreen",
            path: "Sources/YuhKeyScreen"
        )
    ]
)
