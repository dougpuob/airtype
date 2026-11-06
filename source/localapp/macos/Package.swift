// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Experiment: AirType localapp = original Swift shell + local Nemotron streaming ASR (sherpa-onnx).
// The sherpa-onnx prebuilt runtime (osx-arm64 shared) is downloaded by scripts/setup-nemotron.sh.
// Override its location with SHERPA_ONNX_DIR if needed.
let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
let sherpaDir = ProcessInfo.processInfo.environment["SHERPA_ONNX_DIR"]
    ?? "\(home)/.airtype-experiment/runtime/sherpa-onnx-v2.0.1-osx-arm64-shared"
let sherpaLib = "\(sherpaDir)/lib"

let package = Package(
    name: "AirType",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AirType", targets: ["AirType"])
    ],
    targets: [
        // Vendored copy of sherpa-onnx v2.0.1 c-api.h (header only; library is linked from sherpaLib).
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        .executableTarget(
            name: "AirType",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/AirType",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sherpaLib)",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLib,
                ])
            ]
        )
    ]
)
