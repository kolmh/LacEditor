// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterSQL",
    products: [.library(name: "TreeSitterSQL", targets: ["TreeSitterSQL"])],
    targets: [
        .target(
            name: "TreeSitterSQL",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
