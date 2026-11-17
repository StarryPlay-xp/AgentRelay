// swift-tools-version: 6.0
// AgentRelay 的非界面部分：中转核心、relay-mcp、relay-wait、relay-hook 和开发用中转进程 relayd。
// 不依赖任何第三方包；数据库用系统自带的 SQLite，MCP 协议手写（设计方案第 18 节）。

import PackageDescription

let package = Package(
    name: "RelayCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .library(name: "RelayMCP", targets: ["RelayMCP"]),
        .executable(name: "relay-mcp", targets: ["relay-mcp"]),
        .executable(name: "relay-wait", targets: ["relay-wait"]),
        .executable(name: "relay-hook", targets: ["relay-hook"]),
        .executable(name: "relayd", targets: ["relayd"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RelayCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .target(name: "RelayMCP", dependencies: ["RelayCore"]),
        .executableTarget(name: "relay-mcp", dependencies: ["RelayMCP"]),
        .executableTarget(name: "relay-wait", dependencies: ["RelayCore"]),
        .executableTarget(name: "relay-hook", dependencies: ["RelayCore"]),
        .executableTarget(name: "relayd", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayMCPTests", dependencies: ["RelayMCP"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["RelayCore", "relay-mcp", "relay-wait", "relay-hook", "relayd"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
