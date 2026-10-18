@testable import KakurenekoApp
import CoreGraphics
import CoreServices
import KakurenekoKit
import Foundation
import Testing

@Suite("QR codes (CoreImage)", .timeLimit(.minutes(1)))
struct QRCodeTests {
    @Test func rendersACrispSquareCode() throws {
        let link = "https://apps.apple.com/app/id0000000000"
        let image = try #require(QRCode.image(for: link, minimumPixels: 256))
        #expect(image.width == image.height)
        #expect(image.width >= 256)
        // Integer scaling of the generator's module grid (no blurry half modules).
        let unscaled = try #require(QRCode.image(for: link, minimumPixels: 1))
        #expect(image.width % unscaled.width == 0)
    }

    @Test func appLinks() {
        // Not published yet: onboarding explains instead of showing a QR code to a page that does not exist.
        #expect(AppLinks.iPhoneApp == nil)
        #expect(AppLinks.notificationSettings.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kakureneko.Kakureneko")
    }

    @Test func emptyTextHasNoCode() {
        #expect(QRCode.image(for: "") == nil)
    }
}

@Suite("Resume after shutdown (brief §7.5)", .timeLimit(.minutes(1)))
struct ResumeScriptTests {
    @Test func claudeSessionsResumeInTheirDirectory() {
        let entry = ResumeEntry(agent: .claude, sessionId: "3514aa88-efa8-4a60-97d7-2878eed849d4", cwd: "/Users/me/it's here", title: "api")
        #expect(ResumeScript.command(for: entry)
            == "cd '/Users/me/it'\\''s here' && claude --resume 3514aa88-efa8-4a60-97d7-2878eed849d4")
    }

    @Test func missingDirectoryUsesHome() {
        // Kit's resumeCommand: `cd "$HOME"` (a quoted '~' would never expand).
        let entry = ResumeEntry(agent: .claude, sessionId: "s1", cwd: nil, title: nil)
        #expect(ResumeScript.command(for: entry) == #"cd "$HOME" && claude --resume s1"#)
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: "", title: nil)) == #"cd "$HOME" && claude --resume s1"#)
    }

    @Test func backgroundJobsAttach() {
        let entry = ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/x", title: nil, kind: "bg", jobId: "job_42")
        #expect(ResumeScript.command(for: entry) == "claude attach job_42")
    }

    /// `resume.json` is agent-provided data: anything that could escape the shell command is refused.
    @Test func unsafeIdentifiersAreRefused() {
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: "abc; rm -rf ~", cwd: "/x", title: nil)) == nil)
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: "$(id)", cwd: "/x", title: nil)) == nil)
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/x", title: nil, kind: "bg",
                                                      jobId: "j`id`")) == nil)
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/x\nrm -rf ~", title: nil)) == nil)
        #expect(ResumeScript.isSafeIdentifier("thread-7_a.b:c"))
        #expect(!ResumeScript.isSafeIdentifier(""))
        #expect(!ResumeScript.isSafeIdentifier(String(repeating: "a", count: 129)))
        #expect(!ResumeScript.isSafeIdentifier("é"))
    }

    @Test func agentsWithoutAResumeCommandAreSkipped() {
        #expect(ResumeScript.command(for: ResumeEntry(agent: .codex, sessionId: "t1", cwd: "/x", title: nil)) == nil)
        #expect(ResumeScript.command(for: ResumeEntry(agent: .claude, sessionId: nil, cwd: "/x", title: nil)) == nil)
    }

    @Test func terminalChoice() {
        func entry(_ host: HostApp?) -> ResumeEntry { ResumeEntry(agent: .claude, sessionId: "s", cwd: "/x", title: nil, host: host) }
        #expect(ResumeScript.terminalBundleID(for: entry(HostApp(bundleID: "com.googlecode.iterm2", name: "iTerm2"))) == "com.googlecode.iterm2")
        #expect(ResumeScript.terminalBundleID(for: entry(HostApp(bundleID: "com.apple.Terminal", name: "Terminal"))) == "com.apple.Terminal")
        #expect(ResumeScript.terminalBundleID(for: entry(HostApp(bundleID: "com.microsoft.VSCode", name: "VS Code"))) == "com.apple.Terminal")
        #expect(ResumeScript.terminalBundleID(for: entry(nil)) == ResumeScript.defaultTerminalBundleID)
    }

    @Test func commandFileRunsTheCommandThenAShell() {
        let contents = ResumeScript.fileContents(command: "claude attach job_42")
        let lines = contents.components(separatedBy: "\n")
        #expect(lines.first == "#!/bin/zsh -l")
        #expect(lines.contains("claude attach job_42"))
        #expect(lines.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
    }

    @Test func labels() {
        #expect(ResumeScript.label(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/Users/me/api", title: nil)) == "Claude Code · api")
        #expect(ResumeScript.label(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: nil, title: "Fix tests")) == "Claude Code · Fix tests")
        #expect(ResumeScript.label(for: ResumeEntry(agent: .claude, sessionId: "s1", cwd: nil, title: nil)) == "Claude Code · s1")
    }

    @Test @MainActor func recordingReopenerSplitsOpenedAndSkipped() async {
        let reopener = RecordingSessionReopener()
        let report = await reopener.reopen([
            ResumeEntry(agent: .claude, sessionId: "ok", cwd: "/x/api", title: nil),
            ResumeEntry(agent: .codex, sessionId: "t1", cwd: "/x/web", title: nil),
        ])
        #expect(report.opened == ["Claude Code · api"])
        #expect(report.skipped == ["Codex · web"])
    }
}

@Suite("Automation consent and error text", .timeLimit(.minutes(1)))
struct ConsentAndErrorTests {
    @Test func appleEventStatusesMap() {
        #expect(AutomationConsentResult.from(status: OSStatus(noErr)) == .granted)
        #expect(AutomationConsentResult.from(status: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(AutomationConsentResult.from(status: OSStatus(errAEEventWouldRequireUserConsent)) == .notDetermined)
        #expect(AutomationConsentResult.from(status: OSStatus(procNotFound)) == .targetNotRunning)
        #expect(AutomationConsentResult.from(status: -50) == .failed(-50))
        #expect(AutomationConsentResult.granted.isGranted)
        #expect(!AutomationConsentResult.skippedInDryRun.isGranted)
        #expect(AutomationConsentResult.denied.text.contains("sleep instead"))
        #expect(AppleEventAutomationConsent.loginWindowBundleID == "com.apple.loginwindow")
    }

    /// (The DeliveryError/SideEffectError/CancellationError texts are pinned in MenuFormattingTests.errorTexts.)
    @Test func errorDescriptionsPreferTheLocalizedText() {
        let ns = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        #expect(ErrorText.describe(ns) == "Something broke")
        #expect(ErrorText.describe(SideEffectError.unavailable("no helper")) == "Unavailable: no helper")
        #expect(ErrorText.describe(DeliveryError.retryable(after: 90)) == "iCloud could not be reached. Kakureneko retries in 1m.")
    }
}
