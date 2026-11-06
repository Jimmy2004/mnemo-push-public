// swift-tools-version: 5.9
import PackageDescription

// mnemo-e2e：本机 mnemosyne gateway（默认 127.0.0.1:8723）增量同步端到端检查工具。
// 依赖仓库内的 ios/MnemoCore（路径相对本包：tools/e2e -> ../../ios/MnemoCore）。
// path 依赖的 identity 取目录名小写：mnemocore。
let package = Package(
    name: "mnemo-e2e",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mnemo-e2e", targets: ["MnemoE2E"])
    ],
    dependencies: [
        .package(path: "../../ios/MnemoCore")
    ],
    targets: [
        .executableTarget(
            name: "MnemoE2E",
            dependencies: [
                .product(name: "MnemoCore", package: "mnemocore")
            ]
        )
    ]
)
