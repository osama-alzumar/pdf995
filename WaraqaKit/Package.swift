// swift-tools-version: 5.10
// WaraqaKit: the processing core of Waraqa.
//  - WaraqaCore: Foundation-only logic (tool catalog, search, page selection, naming, diffing,
//    Markdown building, server client). Builds and tests on macOS, iOS and Linux.
//  - PDFEngine: the on-device PDF engine (PDFKit, CoreGraphics, CoreText, ImageIO, Vision).
//    Its sources are guarded by `#if canImport(PDFKit)`, so on Linux the target is empty and
//    its tests are skipped; they run on macOS in CI.
import PackageDescription

let package = Package(
    name: "WaraqaKit",
    defaultLocalization: "ar",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WaraqaCore", targets: ["WaraqaCore"]),
        .library(name: "PDFEngine", targets: ["PDFEngine"]),
    ],
    targets: [
        .target(name: "WaraqaCore"),
        .target(name: "PDFEngine", dependencies: ["WaraqaCore"]),
        .testTarget(name: "WaraqaCoreTests", dependencies: ["WaraqaCore"]),
        .testTarget(name: "PDFEngineTests", dependencies: ["PDFEngine", "WaraqaCore"]),
    ]
)
