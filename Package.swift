// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ZoneDesk",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "ZoneDeskCore", targets: ["ZoneDeskCore"]),
        .executable(name: "zonedesk-app", targets: ["ZoneDeskApp"]),
        .executable(name: "zonedesk-probe", targets: ["ZoneDeskProbe"]),
    ],
    targets: [
        .target(name: "ZoneDeskCore"),
        .executableTarget(
            name: "ZoneDeskApp",
            dependencies: ["ZoneDeskCore"]
        ),
        .executableTarget(
            name: "ZoneDeskProbe",
            dependencies: ["ZoneDeskCore"]
        ),
        .testTarget(
            name: "ZoneDeskCoreTests",
            dependencies: ["ZoneDeskCore"]
        ),
        .testTarget(
            name: "ZoneDeskAppTests",
            dependencies: ["ZoneDeskApp"]
        ),
    ]
)
