// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterPython",
    products: [
        .library(name: "TreeSitterPython", targets: ["TreeSitterPython"])
    ],
    targets: [
        .target(
            name: "TreeSitterPython",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
