// swift-tools-version: 6.2
//
// Kakureneko — native macOS menu-bar app (Swift 6 language mode, SwiftPM only, no .xcodeproj).
//
// OWNERSHIP: this file is owned by the architect. Implementation agents must NOT edit it.
// Module dependency rules (binding, see docs/ARCHITECTURE.md):
//   * every library depends on KakurenekoKit only (the shared contracts),
//   * KakurenekoCloud (Mac ⇄ iPhone wire schema over CloudKit) depends on nothing and also builds for iOS: the
//     iPhone app (Xcode/project.yml) links it. KakurenekoKit depends on it (the notification contracts carry its
//     types), and so may every module that names those types (KakurenekoNotify, KakurenekoCoordinator, KakurenekoApp),
//   * KakurenekoCoordinator depends on all libraries,
//   * KakurenekoGuard may depend on KakurenekoPause,
//   * KakurenekoHook depends on nothing (Darwin-only, no Foundation).
//   * The only external dependency is Sparkle (Mac app updates, KakurenekoApp only; docs/RELEASE.md). Exact version:
//     update it deliberately.
// Product names must differ case-insensitively from each other (APFS clash, R08 §1):
//   KakurenekoApp (bundled as Contents/MacOS/Kakureneko), kakureneko-hook, kakureneko-guard.

import PackageDescription

/// Strict settings from brief §9.1 / R08 §2 (verified with Swift 6.3.3).
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),      // SE-0470
    .enableUpcomingFeature("MemberImportVisibility"),          // SE-0444
]

let package = Package(
    name: "Kakureneko",
    // iOS only for KakurenekoCloud (the iPhone app in Xcode/project.yml); every other target is macOS-only.
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "KakurenekoCloud", targets: ["KakurenekoCloud"]),
        .executable(name: "KakurenekoApp", targets: ["KakurenekoApp"]),
        .executable(name: "kakureneko-hook", targets: ["KakurenekoHook"]),
        .executable(name: "kakureneko-guard", targets: ["KakurenekoGuard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // MARK: Contracts (architect-owned)
        .target(
            name: "KakurenekoKit",
            dependencies: ["KakurenekoCloud"],
            swiftSettings: strict
        ),
        // Shared with the iPhone app: record schema, codecs, command validation (docs/NATIVE-NOTIFICATIONS.md).
        .target(
            name: "KakurenekoCloud",
            swiftSettings: strict
        ),

        // MARK: Feature libraries (one owner each)
        .target(
            name: "KakurenekoEvents",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict
        ),
        .target(
            name: "KakurenekoProcesses",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "KakurenekoSessions",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict
        ),
        .target(
            name: "KakurenekoPower",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "KakurenekoPause",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio")]
        ),
        .target(
            name: "KakurenekoNotify",
            dependencies: ["KakurenekoKit", "KakurenekoCloud"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        .target(
            name: "KakurenekoInstall",
            dependencies: ["KakurenekoKit"],
            swiftSettings: strict
        ),
        .target(
            name: "KakurenekoCoordinator",
            dependencies: [
                "KakurenekoKit",
                "KakurenekoCloud",
                "KakurenekoEvents",
                "KakurenekoProcesses",
                "KakurenekoSessions",
                "KakurenekoPower",
                "KakurenekoPause",
                "KakurenekoNotify",
                "KakurenekoInstall",
            ],
            swiftSettings: strict
        ),

        // MARK: Executables
        .executableTarget(
            name: "KakurenekoApp",
            dependencies: ["KakurenekoKit", "KakurenekoCloud", "KakurenekoCoordinator",
                           .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: strict + [.defaultIsolation(MainActor.self)] // SE-0466
        ),
        .executableTarget(
            name: "KakurenekoHook",
            dependencies: [], // deliberately dependency-free: Darwin + notify only (brief §4.2)
            swiftSettings: strict
        ),
        .executableTarget(
            name: "KakurenekoGuard",
            dependencies: ["KakurenekoKit", "KakurenekoPause"],
            swiftSettings: strict
        ),

        // MARK: Tests (Swift Testing)
        .testTarget(name: "KakurenekoKitTests", dependencies: ["KakurenekoKit", "KakurenekoCloud"], swiftSettings: strict),
        .testTarget(name: "KakurenekoCloudTests", dependencies: ["KakurenekoCloud"], swiftSettings: strict),
        .testTarget(
            name: "KakurenekoEventsTests",
            dependencies: ["KakurenekoEvents", "KakurenekoKit", "KakurenekoHook"], // KakurenekoHook => `swift test` builds kakureneko-hook
            swiftSettings: strict
        ),
        .testTarget(name: "KakurenekoProcessesTests", dependencies: ["KakurenekoProcesses", "KakurenekoKit"], swiftSettings: strict),
        .testTarget(name: "KakurenekoSessionsTests", dependencies: ["KakurenekoSessions", "KakurenekoKit"], swiftSettings: strict),
        .testTarget(name: "KakurenekoPowerTests", dependencies: ["KakurenekoPower", "KakurenekoKit"], swiftSettings: strict),
        .testTarget(
            name: "KakurenekoPauseTests",
            dependencies: ["KakurenekoPause", "KakurenekoKit", "KakurenekoGuard"], // KakurenekoGuard => `swift test` builds kakureneko-guard
            swiftSettings: strict
        ),
        .testTarget(name: "KakurenekoNotifyTests", dependencies: ["KakurenekoNotify", "KakurenekoKit", "KakurenekoCloud"], swiftSettings: strict),
        .testTarget(name: "KakurenekoInstallTests", dependencies: ["KakurenekoInstall", "KakurenekoKit"], swiftSettings: strict),
        .testTarget(name: "KakurenekoCoordinatorTests", dependencies: ["KakurenekoCoordinator", "KakurenekoKit", "KakurenekoCloud"], swiftSettings: strict),
        .testTarget(name: "KakurenekoAppTests", dependencies: ["KakurenekoApp", "KakurenekoKit", "KakurenekoCloud"], swiftSettings: strict),
    ]
)
