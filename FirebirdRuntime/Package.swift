// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FirebirdRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // FirebirdCore has no MLX dependency: recipe, device budget, loop
    // detection and metrics build and test on any platform.
    products: [.library(name: "FirebirdRuntime", targets: ["FirebirdRuntime", "FirebirdCore"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.0")
    ],
    targets: [
        .target(name: "FirebirdCore"),
        .target(name: "FirebirdRuntime", dependencies: [
            "FirebirdCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Transformers", package: "swift-transformers")
        ], resources: [.copy("Kernels/FirebirdAttention.metal.txt")]),
        .testTarget(name: "FirebirdCoreTests", dependencies: ["FirebirdCore"]),
        .testTarget(name: "FirebirdRuntimeTests", dependencies: ["FirebirdRuntime"])
    ]
)
