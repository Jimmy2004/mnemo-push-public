// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MnemoCore", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "MnemoCore", targets: ["MnemoCore"])],
    targets: [.target(name: "MnemoCore"), .testTarget(name: "MnemoCoreTests", dependencies: ["MnemoCore"])])
