// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneFlow",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaneFlow", targets: ["PaneFlow"]),
               .executable(name: "PaneFlowPractice", targets: ["PaneFlowPractice"]),
               .executable(name: "PaneFlowChecks", targets: ["PaneFlowChecks"])],
    targets: [.target(name: "PaneFlowCore"),
              .executableTarget(name: "PaneFlow", dependencies: ["PaneFlowCore"]),
              .executableTarget(name: "PaneFlowPractice"),
              .executableTarget(name: "PaneFlowChecks", dependencies: ["PaneFlowCore"])],
    swiftLanguageModes: [.v5]
)
