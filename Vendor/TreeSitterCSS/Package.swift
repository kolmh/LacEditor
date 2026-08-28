// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterCSS",
    products: [
        .library(name: "TreeSitterCSS", targets: ["TreeSitterCSS"])
    ],
    targets: [
        .target(
            name: "TreeSitterCSS",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
