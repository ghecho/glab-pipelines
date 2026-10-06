// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pipelines",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PipelineCore"),
        .executableTarget(name: "Pipelines", dependencies: ["PipelineCore"]),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore"]
        ),
    ]
)
