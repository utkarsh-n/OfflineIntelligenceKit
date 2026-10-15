// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OfflineIntelligenceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OfflineIntelligence", targets: ["OfflineIntelligence"]),
        .library(name: "OfflineIntelligenceBenchmarks", targets: ["OfflineIntelligenceBenchmarks"]),
    ],
    targets: [
        .target(name: "OfflineIntelligence"),
        .target(name: "OfflineIntelligenceBenchmarks", dependencies: ["OfflineIntelligence"]),
        .testTarget(name: "OfflineIntelligenceTests", dependencies: ["OfflineIntelligence"]),
        .testTarget(name: "OfflineIntelligenceBenchmarksTests", dependencies: ["OfflineIntelligenceBenchmarks"]),
    ],
    swiftLanguageModes: [.v6]
)
