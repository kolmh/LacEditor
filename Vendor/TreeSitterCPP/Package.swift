// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterCPP",
    products: [.library(name: "TreeSitterCPP", targets: ["TreeSitterCPP"])],
    targets: [
        .target(
            name: "TreeSitterCPP",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
