// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterC",
    products: [.library(name: "TreeSitterC", targets: ["TreeSitterC"])],
    targets: [
        .target(
            name: "TreeSitterC",
            path: ".",
            sources: ["src/parser.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
