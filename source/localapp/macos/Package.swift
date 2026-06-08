// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AirTypeMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AirTypeMac", targets: ["AirTypeMac"])
    ],
    targets: [
        .executableTarget(
            name: "AirTypeMac",
            path: "Sources/AirTypeMac"
        )
    ]
)
