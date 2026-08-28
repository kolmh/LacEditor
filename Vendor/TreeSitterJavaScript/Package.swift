// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterJavaScript",
    products: [
        .library(name: "TreeSitterJavaScript", targets: ["TreeSitterJavaScript"])
    ],
    targets: [
        .target(
            name: "TreeSitterJavaScript",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
