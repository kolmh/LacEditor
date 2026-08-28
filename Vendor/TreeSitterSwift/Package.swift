// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterSwift",
    products: [.library(name: "TreeSitterSwift", targets: ["TreeSitterSwift"])],
    targets: [
        .target(
            name: "TreeSitterSwift",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
