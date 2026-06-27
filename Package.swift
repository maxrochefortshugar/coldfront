// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mlx-chill",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "mlx-chill", targets: ["mlx-chill"]),
        .executable(name: "mlx-chill-control", targets: ["mlx-chill-control"]),
        .library(name: "FanProbeCore", targets: ["FanProbeCore"])
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "FanProbeCore",
            dependencies: ["CSMC"]
        ),
        .target(
            name: "FanControlCore"
        ),
        .target(
            name: "SMCControlTransport",
            dependencies: ["FanControlCore"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "mlx-chill",
            dependencies: ["FanProbeCore"]
        ),
        .executableTarget(
            name: "mlx-chill-control",
            dependencies: ["FanControlCore", "SMCControlTransport"]
        ),
        .executableTarget(
            name: "FanProbeCoreTestRunner",
            dependencies: ["FanProbeCore"],
            path: "Tests/FanProbeCoreTestRunner"
        ),
        .executableTarget(
            name: "FanControlCoreTestRunner",
            dependencies: ["FanControlCore", "SMCControlTransport"],
            path: "Tests/FanControlCoreTestRunner"
        )
    ]
)
