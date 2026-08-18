// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CodexWidgetShared",
            resources: [.copy("Resources/codex-widget-icon.png")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ClaudeNotch",
            dependencies: [
                "CodexWidgetShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/codex.svg"),
                .copy("Resources/codex.png"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexQuotaWidget",
            dependencies: ["CodexWidgetShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexWidgetRender",
            dependencies: ["CodexWidgetShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeNotchTests",
            dependencies: ["ClaudeNotch"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
