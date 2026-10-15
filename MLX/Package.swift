// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OfflineIntelligenceMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OfflineIntelligenceMLX", targets: ["OfflineIntelligenceMLX"])],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
        .package(url: "https://github.com/apple/swift-collections", exact: "1.5.0"),
    ],
    targets: [.target(name: "OfflineIntelligenceMLX", dependencies: [
        .product(name: "OfflineIntelligence", package: "OfflineIntelligenceKit"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ])],
    swiftLanguageModes: [.v6]
)
