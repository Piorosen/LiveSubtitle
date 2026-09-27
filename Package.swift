// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubtitle",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet TDT (NVIDIA) CoreML 음성 인식 — 영어 전용 v2 모델 사용
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "LiveSubtitle",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
