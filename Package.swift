// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DOT-LanguageKit",
    platforms: [.macOS(.v13), .iOS(.v14)],
    products: [.library(name: "DOTLanguage", targets: ["DOTLanguage"])],
    dependencies: [
        .package(url: "https://github.com/hakkabon/Grammar.git", .upToNextMinor(from: "0.9.1")),
        .package(url: "https://github.com/hakkabon/Lexer.git", .upToNextMinor(from: "0.9.1")),
        .package(url: "https://github.com/hakkabon/Parser.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/hakkabon/Incremental-Parsing.git", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/hakkabon/Language-Tooling.git", .upToNextMinor(from: "0.10.2")),
    ],
    targets: [
        .target(name: "DOTLanguage", dependencies: [
            .product(name: "Grammar", package: "Grammar"),
            .product(name: "Lexer", package: "Lexer"),
            .product(name: "Parser", package: "Parser"),
            .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            .product(name: "LanguageTooling", package: "Language-Tooling"),
        ]),
        .testTarget(name: "DOTLanguageTests", dependencies: [
            "DOTLanguage",
            .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
        ]),
    ])
