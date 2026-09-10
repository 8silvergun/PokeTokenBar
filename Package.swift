// swift-tools-version: 6.0
import PackageDescription

#if os(Windows)
let platformExcludes = [
    "PokeTokenBarApp.swift",
    "UI",
    "Core/CrashReporter.swift",
    "Core/LoginItem.swift",
    "Core/NetworkReachabilityMonitor.swift",
    "Core/SingleInstance.swift",
    "Core/UpdateChecker.swift",
    "Core/UsageStore.swift",
    "Core/AppLog.swift",
    "Core/BinaryLocator.swift",
    "Core/ProcessRunner.swift",
]
#else
let platformExcludes = [
    "WindowsAutostart.swift",
    "WindowsImaging.swift",
    "WindowsMain.swift",
    "WindowsProcess.swift",
    "WindowsSupport.swift",
    "WindowsTray.swift",
    "WindowsUpdate.swift",
    "WindowsCore",
]
#endif

let package = Package(
    name: "PokeTokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PokeTokenBar",
            dependencies: [
                // swift-corelibs on Windows has no system SQLite3 module. Keep the
                // source-level `import SQLite3` API stable by providing a local C
                // module with the same module name only on Windows.
                .target(name: "SQLite3", condition: .when(platforms: [.windows])),
            ],
            path: "Sources/PokeTokenBar",
            exclude: platformExcludes,
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
                // Tray application: avoid flashing a console on normal launch.
                .unsafeFlags([
                    "-Xlinker", "/SUBSYSTEM:WINDOWS",
                    "-Xlinker", "/ENTRY:mainCRTStartup",
                ], .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "SQLite3",
            path: "Sources/CSQLite"
        ),
        .testTarget(
            name: "PokeTokenBarTests",
            dependencies: [
                "PokeTokenBar",
                .target(name: "SQLite3", condition: .when(platforms: [.windows])),
            ],
            path: "Tests/PokeTokenBarTests",
            resources: [
                .copy("Fixtures/CodexFork"),
                .copy("Fixtures/CodexSubagent"),
            ]
        ),
    ]
)
