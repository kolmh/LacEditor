// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterHTML",
    products: [
        .library(name: "TreeSitterHTML", targets: ["TreeSitterHTML"])
    ],
    targets: [
        .target(
            name: "TreeSitterHTML",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
