// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterBash",
    products: [.library(name: "TreeSitterBash", targets: ["TreeSitterBash"])],
    targets: [
        .target(
            name: "TreeSitterBash",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
