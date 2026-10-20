// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MeshCoreKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "AppFeature", targets: ["AppFeature"]),
    .library(name: "MeshCoreClient", targets: ["MeshCoreClient"]),
    .library(name: "MeshCoreProtocol", targets: ["MeshCoreProtocol"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.26.0"
    ),
  ],
  targets: [
    // Pure, platform-independent codec for the MeshCore companion radio protocol.
    // No UI or Bluetooth dependencies so it can be unit tested anywhere.
    .target(name: "MeshCoreProtocol"),
    .testTarget(
      name: "MeshCoreProtocolTests",
      dependencies: ["MeshCoreProtocol"]
    ),

    // Transport (CoreBluetooth Nordic UART + demo radio), serialized command
    // pipeline and the TCA dependency client used by features.
    .target(
      name: "MeshCoreClient",
      dependencies: [
        "MeshCoreProtocol",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "MeshCoreClientTests",
      dependencies: ["MeshCoreClient"]
    ),

    // All TCA reducers and SwiftUI views.
    .target(
      name: "AppFeature",
      dependencies: [
        "MeshCoreClient",
        "MeshCoreProtocol",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "AppFeatureTests",
      dependencies: [
        "AppFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
  ],
  swiftLanguageModes: [.v5]
)
