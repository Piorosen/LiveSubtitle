// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "asreval",
    platforms: [.macOS(.v15)],
    dependencies: [ .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4") ],
    targets: [
        .executableTarget(name: "streamtest", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "asreval", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
