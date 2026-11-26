// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RestABit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RestABit", targets: ["RestABit"])],
    targets: [
        .target(name: "RestABitCore"),
        .executableTarget(name: "RestABit", dependencies: ["RestABitCore"], resources: [.copy("Assets")]),
        .testTarget(name: "RestABitCoreTests", dependencies: ["RestABitCore"])
    ]
)
