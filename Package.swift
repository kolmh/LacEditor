// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LacEditor",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            exact: "0.8.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "LacEditor",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
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
