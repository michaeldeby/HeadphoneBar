// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HeadphoneBar", platforms: [.macOS(.v14)],
    products: [.executable(name: "HeadphoneBar", targets: ["HeadphoneBar"])],
    targets: [
        .target(name: "HeadphoneProtocol"),
        .target(name: "MomentumCore", path: "Vendor/Momentum/Sources/MomentumCore"),
        .target(name: "MomentumBluetooth", dependencies: ["MomentumCore"], path: "Vendor/Momentum/Sources/MomentumBluetooth", linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "HeadphoneBar", dependencies: ["HeadphoneProtocol", "MomentumCore", "MomentumBluetooth"], linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]),
        .executableTarget(name: "HeadphoneProtocolTests", dependencies: ["HeadphoneProtocol", "MomentumCore"], path: "Tests/HeadphoneProtocolTests")
    ], swiftLanguageModes: [.v5]
)
