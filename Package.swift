// swift-tools-version: 6.0
import PackageDescription

#if os(Windows)
let executableExcludes = [
    // Keep upstream macOS Core untouched. The Windows port is first restored
    // against the previously proven compatibility snapshot, then forward-ported
    // component-by-component to the current Core.
    "Core",
    "UI",
    "PokeTokenBarApp.swift",
]
let executableDependencies: [Target.Dependency] = ["SQLite3"]
let sqliteTargets: [Target] = [
    .target(name: "SQLite3", path: "Sources/CSQLite")
]
let testTargets: [Target] = [
    .testTarget(
        name: "PokeTokenBarWindowsTests",
        dependencies: ["PokeTokenBar"],
        path: "Tests/PokeTokenBarWindowsTests"
    )
]
#else
let executableExcludes = [
    "WindowsCore",
    "WindowsAutostart.swift",
    "WindowsImaging.swift",
    "WindowsMain.swift",
    "WindowsProcess.swift",
    "WindowsSupport.swift",
    "WindowsTray.swift",
    "WindowsUpdate.swift",
]
let executableDependencies: [Target.Dependency] = []
let sqliteTargets: [Target] = []
let testTargets: [Target] = [
    .testTarget(
        name: "PokeTokenBarTests",
        dependencies: ["PokeTokenBar"],
        path: "Tests/PokeTokenBarTests",
        resources: [
            .copy("Fixtures/CodexFork"),
            .copy("Fixtures/CodexSubagent"),
        ]
    )
]
#endif

let package = Package(
    name: "PokeTokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PokeTokenBar",
            dependencies: executableDependencies,
            path: "Sources/PokeTokenBar",
            exclude: executableExcludes,
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
                // Tray application: avoid flashing a console on normal launch.
                .unsafeFlags([
                    "-Xlinker", "/SUBSYSTEM:WINDOWS",
                    "-Xlinker", "/ENTRY:mainCRTStartup",
                ], .when(platforms: [.windows])),
            ]
        ),
    ] + sqliteTargets + testTargets
)
