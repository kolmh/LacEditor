// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterYAML",
    products: [.library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"])],
    targets: [
        .target(
            name: "TreeSitterYAML",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c", "src/schema.core.c", "src/schema.json.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
