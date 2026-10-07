// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pipelines",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PipelineCore"),
        .executableTarget(
            name: "Pipelines",
            dependencies: ["PipelineCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore"]
        ),
    ]
)
