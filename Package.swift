// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapsDocsCapture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CapsDocsCapture",
            path: "Sources/CapsDocsCapture"
        )
    ]
)
