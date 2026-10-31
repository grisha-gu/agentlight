// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentLight",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "agentlightd", targets: ["agentlightd"]),
        .executable(name: "agentlight", targets: ["agentlight"]),
    ],
    targets: [
        .target(name: "AgentLightKit"),
        .executableTarget(name: "agentlightd", dependencies: ["AgentLightKit"]),
        .executableTarget(name: "agentlight", dependencies: ["AgentLightKit"]),
        .testTarget(name: "AgentLightKitTests", dependencies: ["AgentLightKit"]),
    ],
    swiftLanguageModes: [.v5]
)
