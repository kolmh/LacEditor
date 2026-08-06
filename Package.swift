// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LacEditor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LacEditor",
            path: "LacEditor",
            exclude: ["Assets.xcassets"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "LacEditorTests",
            dependencies: ["LacEditor"],
            path: "LacEditorTests"
        )
    ]
)
