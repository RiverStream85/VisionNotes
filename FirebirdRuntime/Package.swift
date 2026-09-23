// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FirebirdRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FirebirdRuntime", targets: ["FirebirdRuntime"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.0")
    ],
    targets: [
        .target(name: "FirebirdRuntime", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Transformers", package: "swift-transformers")
        ], resources: [.copy("Kernels/FirebirdAttention.metal.txt")]),
        .testTarget(name: "FirebirdRuntimeTests", dependencies: ["FirebirdRuntime"])
    ]
)
