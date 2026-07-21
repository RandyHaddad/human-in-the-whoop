// swift-tools-version: 6.1
import PackageDescription

let commandLineToolsTestingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F", commandLineToolsTestingFrameworks]),
]
let testLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-F", commandLineToolsTestingFrameworks]),
]

let package = Package(
    name: "HumanInTheWhoop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HumanInTheWhoopCore", targets: ["HumanInTheWhoopCore"]),
        .library(name: "HumanInTheWhoopWHOOP", targets: ["HumanInTheWhoopWHOOP"]),
        .library(name: "HumanInTheWhoopAppSupport", targets: ["HumanInTheWhoopAppSupport"]),
        .executable(name: "hitw-hook", targets: ["HITWHook"]),
        .executable(name: "hitwctl", targets: ["HITWControl"]),
        .executable(name: "human-in-the-whoop-menubar", targets: ["HumanInTheWhoopMenuBar"]),
    ],
    targets: [
        .target(
            name: "HumanInTheWhoopCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HumanInTheWhoopWHOOP",
            dependencies: ["HumanInTheWhoopCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "HumanInTheWhoopAppSupport",
            dependencies: ["HumanInTheWhoopCore", "HumanInTheWhoopWHOOP"],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .target(
            name: "HumanInTheWhoopControlSupport",
            dependencies: ["HumanInTheWhoopCore"]
        ),
        .executableTarget(
            name: "HITWHook",
            dependencies: ["HumanInTheWhoopCore"]
        ),
        .executableTarget(
            name: "HITWControl",
            dependencies: [
                "HumanInTheWhoopCore",
                "HumanInTheWhoopWHOOP",
                "HumanInTheWhoopControlSupport",
            ]
        ),
        .executableTarget(
            name: "HumanInTheWhoopMenuBar",
            dependencies: [
                "HumanInTheWhoopCore",
                "HumanInTheWhoopWHOOP",
                "HumanInTheWhoopAppSupport",
            ]
        ),
        .testTarget(
            name: "HumanInTheWhoopCoreTests",
            dependencies: ["HumanInTheWhoopCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "HumanInTheWhoopWHOOPTests",
            dependencies: ["HumanInTheWhoopWHOOP", "HumanInTheWhoopCore"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "HumanInTheWhoopAppSupportTests",
            dependencies: ["HumanInTheWhoopAppSupport", "HumanInTheWhoopCore"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "HITWControlTests",
            dependencies: [
                "HumanInTheWhoopControlSupport",
                "HumanInTheWhoopCore",
            ],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "HITWHookIntegrationTests",
            dependencies: ["HumanInTheWhoopCore", "HITWHook"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
