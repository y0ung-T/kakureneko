@testable import KakurenekoApp
import AppKit
import KakurenekoKit
import Foundation
import Testing

/// Static checks of the bundle inputs, the scripts and the app sources. Nothing here builds, signs, installs or
/// launches anything (`scripts/build-app.sh` is verified by hand per ARCHITECTURE §10; `install.sh` is user-only).
@Suite("Bundle resources, scripts and source rules", .timeLimit(.minutes(1)))
struct ProjectFilesTests {
    private let root = repositoryRoot()

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }

    private func isExecutable(_ relative: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appending(path: relative).path(percentEncoded: false))
    }

    private func plist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: relative))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: Settings the UI offers are implemented

    /// Every `PauseSettings` field the settings window binds is read by the module that implements it (review
    /// finding: "Let frozen apps breathe" was shown and saved, but nothing implemented it).
    @Test func everyPausingSettingTheUIBindsIsImplemented() throws {
        let view = try text("Sources/KakurenekoApp/Views/SettingsView.swift")
        let pattern = try Regex(#"\\\.pausing\.([A-Za-z]+)"#)
        let bound = Set(view.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) })
        #expect(bound.contains("mode"))
        #expect(!bound.contains("breathing"))
        let directories = ["Sources/KakurenekoPause", "Sources/KakurenekoCoordinator"]
        var implementation = ""
        for directory in directories {
            let url = root.appending(path: directory)
            for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) ?? .init()
            where file.pathExtension == "swift" {
                implementation += try String(contentsOf: file, encoding: .utf8)
            }
        }
        for field in bound {
            #expect(implementation.contains(".\(field)"), "\(field) is offered in Settings but never read")
        }
    }

    // MARK: Info.plist and entitlements

    @Test func infoPlistDescribesAMenuBarApp() throws {
        let info = try plist("Resources/Info.plist")
        #expect(info["CFBundleIdentifier"] as? String == KakurenekoID.bundleIdentifier)
        #expect(info["CFBundleExecutable"] as? String == "Kakureneko")
        #expect(info["CFBundleName"] as? String == KakurenekoID.appName)
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["LSMinimumSystemVersion"] as? String == "26.0")
        #expect((info["NSAppleEventsUsageDescription"] as? String)?.isEmpty == false)
        // The phone path is ntfy: no user-notification usage keys are needed.
        #expect(info["NSUserNotificationsUsageDescription"] == nil)
    }

    @Test func entitlementsAllowOnlyAppleEvents() throws {
        let entitlements = try plist("Resources/Kakureneko.entitlements")
        #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(entitlements["com.apple.security.app-sandbox"] == nil)
        #expect(entitlements.count == 1)
    }

    @Test func appIconIsAnIcnsFile() throws {
        let data = try Data(contentsOf: root.appending(path: "Resources/AppIcon.icns"))
        #expect(data.count > 1024)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "icns")
    }

    // MARK: Scripts (read, never run)

    @Test func buildScriptAssemblesAndVerifiesTheBundle() throws {
        #expect(isExecutable("scripts/build-app.sh"))
        let script = try text("scripts/build-app.sh")
        #expect(script.hasPrefix("#!/usr/bin/env bash"))
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("Contents/MacOS/Kakureneko"))
        #expect(script.contains("Contents/Helpers/kakureneko-hook"))
        #expect(script.contains("Contents/Helpers/kakureneko-guard"))
        #expect(script.contains("--identifier com.kakureneko.hook"))
        #expect(script.contains("--identifier com.kakureneko.guard"))
        #expect(script.contains("ENTITLEMENTS=\"Resources/Kakureneko.entitlements\""))
        #expect(script.contains("--entitlements \"$ENTITLEMENTS\""))
        // iCloud: the profile is embedded and the cloud entitlements merged only when a profile exists.
        #expect(script.contains("Contents/embedded.provisionprofile"))
        #expect(script.contains("Merge Resources/KakurenekoCloud.entitlements"))
        #expect(script.contains("NO_CLOUD"))
        #expect(script.contains("Resources/AppIcon.icns"))
        #expect(script.contains("codesign --verify --deep --strict"))
        // Builds only: never launches, installs or registers.
        #expect(!script.contains("open "))
        #expect(!script.contains("ditto"))
        // Sparkle in every build (the binary links it), signed inside-out before the app.
        #expect(script.contains("Contents/Frameworks/Sparkle.framework"))
        #expect(script.contains("install_name_tool -add_rpath @executable_path/../Frameworks"))
        #expect(script.contains("\"$FW/Versions/B/Autoupdate\""))
        // The download: Developer ID, universal, notarizable, production iCloud, Sparkle's feed and key.
        #expect(script.contains("DISTRIBUTION"))
        #expect(script.contains("Developer ID Application:"))
        #expect(script.contains("ARCHS=(arm64 x86_64)"))
        #expect(script.contains("lipo -create"))
        #expect(script.contains("TIMESTAMP=(--timestamp)"))
        #expect(script.contains("Set :com.apple.developer.aps-environment production"))
        #expect(script.contains("icloud-container-environment string Production"))
        #expect(script.contains("SUFeedURL") && script.contains("SUPublicEDKey"))
        #expect(script.contains("source scripts/release.env"))
    }

    @Test func releaseScriptNotarizesAndPublishesButNeverEscalates() throws {
        #expect(isExecutable("scripts/release-mac.sh"))
        let script = try text("scripts/release-mac.sh")
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("HUMAN-RUN"))
        #expect(script.contains("DISTRIBUTION=1 scripts/build-app.sh release"))
        #expect(script.contains("xcrun notarytool submit"))
        #expect(script.contains("xcrun stapler staple \"$APP\"") && script.contains("xcrun stapler staple \"$dmg\""))
        #expect(script.contains("hdiutil create"))
        #expect(script.contains("ln -s /Applications"))
        #expect(script.contains("sign_update"))
        #expect(script.contains("pathlib.Path(\"appcast.xml\")"))
        #expect(script.contains("gh release create"))
        #expect(script.contains("<string>developer-id</string>"))
        #expect(!script.contains("sudo"))
        let env = try text("scripts/release.env")
        for key in ["VERSION=", "BUILD_NUMBER=", "WEBSITE_URL=", "APPCAST_URL=", "IPHONE_APP_URL=", "COPYRIGHT=", "SPARKLE_PUBLIC_KEY=",
                    "NOTARY_PROFILE=", "TEAM_ID=7NRW73MYQZ"] {
            #expect(env.contains("\n\(key)"), "\(key)")
        }
    }

    @Test func installScriptBuildsCopiesAndOpens() throws {
        #expect(isExecutable("scripts/install.sh"))
        let script = try text("scripts/install.sh")
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("scripts/build-app.sh"))
        #expect(script.contains("$HOME/Applications"))
        #expect(script.contains("ditto \"$SRC\""))
        #expect(script.contains("open \"$APP\""))
        #expect(script.contains("USER ONLY"))
        // Never escalates privileges.
        #expect(!script.contains("sudo"))
        #expect(!script.contains("administrator privileges"))
    }

    @Test func iconScriptRendersTheDesignLanguageArtwork() throws {
        #expect(isExecutable("scripts/make-icon.sh"))
        let script = try text("scripts/make-icon.sh")
        #expect(script.contains("iconutil --convert icns --output Resources/AppIcon.icns"))
        #expect(script.contains("design language/artwork"))
        for file in ["design language/artwork/render.swift", "scripts/flatten-png.swift"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: file).path(percentEncoded: false)), "\(file)")
        }
    }

    /// Every menu bar state has its cat glyph at 1x and 2x, every pose its plain and sticker SVG, for both apps;
    /// build-app.sh copies them into the bundle.
    @Test func designArtworkIsInPlace() throws {
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) }
        for name in MenuBarIcon.allImageNames {
            #expect(exists("Resources/MenuBar/\(name).png") && exists("Resources/MenuBar/\(name)@2x.png"), "\(name)")
        }
        for pose in MascotPose.allCases.map(\.rawValue) {
            #expect(exists("Resources/Mascot/\(pose).svg") && exists("Resources/Mascot/\(pose)-sticker.svg"), "\(pose)")
            let set = "iPhone/App/Resources/Assets.xcassets/Mascot/\(pose).imageset"
            #expect(exists("\(set)/\(pose).svg") && exists("\(set)/\(pose)-sticker.svg") && exists("\(set)/Contents.json"), "\(pose)")
        }
        let build = try text("scripts/build-app.sh")
        #expect(build.contains("for dir in MenuBar Mascot"))
    }

    @MainActor @Test func artworkLoadsFromTheResources() {
        let previous = Artwork.resources
        defer { Artwork.resources = previous }
        Artwork.resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        for name in MenuBarIcon.allImageNames {
            let glyph = Artwork.menuBarGlyph(name)
            #expect(glyph?.isTemplate == true, "\(name)")
            #expect(glyph?.representations.count == 2, "\(name)")
        }
        for pose in MascotPose.allCases {
            #expect(Artwork.mascot(pose, dark: false) != nil, "\(pose)")
            #expect(Artwork.mascot(pose, dark: true) != nil, "\(pose)")
        }
        Artwork.resources = nil
        #expect(Artwork.menuBarGlyph("working") == nil)
    }

    // MARK: Source rules (spec card §9.9)

    /// Every Swift file of the app target, with comment lines removed (docs may name the APIs).
    private func appSources() throws -> [(name: String, text: String)] {
        let directory = root.appending(path: "Sources/KakurenekoApp", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            files.append((url.lastPathComponent, code))
        }
        return files
    }

    /// The phone path is ntfy: the app never asks for notification authorization.
    @Test func neverRequestsNotificationAuthorization() throws {
        let sources = try appSources()
        #expect(sources.count >= 10)
        for (name, text) in sources {
            #expect(!text.contains("UserNotifications"), "\(name)")
            #expect(!text.contains("UNUserNotificationCenter"), "\(name)")
            #expect(!text.contains("requestAuthorization"), "\(name)")
        }
    }

    /// Every SF Symbol named in the app (`systemName:`, `systemImage:`, `symbolName:`, `symbol:` literals and the
    /// formatter tables) exists on this macOS; a typo would render as an empty image.
    @Test @MainActor func everySymbolResolves() throws {
        let pattern = try Regex(#"(?:systemName|systemImage|symbolName|symbol): "([A-Za-z0-9.]+)""#)
        var names = Set<String>()
        for (_, text) in try appSources() {
            for match in text.matches(of: pattern) {
                if let name = match.output[1].substring { names.insert(String(name)) }
            }
            // `case .x: "symbol.name"` tables in the formatters.
            for match in text.matches(of: try Regex(#"case [.a-zA-Z, ]+: "([a-z0-9]+(?:\.[a-z0-9]+)+)""#)) {
                if let name = match.output[1].substring { names.insert(String(name)) }
            }
        }
        names.formUnion(MenuBarIcon.allSymbolNames)
        names.formUnion(SettingsPane.allCases.map(\.symbolName))
        names.formUnion(OnboardingFlow.Step.allCases.map(\.symbolName))
        #expect(names.count >= 30)
        for name in names.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }

    /// SMAppService is reached only through `MainAppLoginItem` (which tests never build) and the coordinator only
    /// through `KakurenekoControlling`.
    @Test func systemServicesAreBehindTheEnvironment() throws {
        for (name, text) in try appSources() {
            if name != "AppEnvironment.swift" {
                #expect(!text.contains("SMAppService"), "\(name)")
                #expect(!text.contains("AEDeterminePermissionToAutomateTarget"), "\(name)")
            }
            if name != "KakurenekoApp.swift" {
                #expect(!text.contains("KakurenekoCoordinator.live"), "\(name)")
            }
        }
    }
}
