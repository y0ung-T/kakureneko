// AppKit-hosted windows for the settings and onboarding screens. A menu-bar-only (LSUIElement) app has no
// regular window scene to rely on, so the windows are plain `NSWindow`s around `NSHostingController`, created on
// demand, kept (not released) when closed, and brought to the front with `NSApp.activate()`.

import AppKit
import KakurenekoKit
import SwiftUI

final class WindowCoordinator: NSObject, WindowPresenting, NSWindowDelegate {
    private let model: AppModel
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingFlow: OnboardingFlow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: WindowPresenting

    func showSettings(pane: SettingsPane?) {
        if let pane { model.settingsPane = pane }
        let window = settingsWindow ?? makeWindow(
            title: "\(KakurenekoID.appName) Settings",
            size: NSSize(width: 800, height: 620),
            autosaveName: "KakurenekoSettingsWindow",
            content: SettingsView(model: model))
        settingsWindow = window
        present(window)
    }

    func showOnboarding() {
        if onboardingFlow == nil || onboardingFlow?.isFinished == true {
            onboardingFlow = OnboardingFlow(model: model)
            onboardingWindow?.close()
            onboardingWindow = nil
        }
        guard let flow = onboardingFlow else { return }
        let window = onboardingWindow ?? makeWindow(
            title: "Welcome to \(KakurenekoID.appName)",
            size: NSSize(width: 760, height: 660),
            autosaveName: "KakurenekoOnboardingWindow",
            content: OnboardingView(flow: flow))
        onboardingWindow = window
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow, model.settingsDraft.isDirty {
            // Closing the settings window keeps the edits (macOS settings apply as you go).
            Task { await model.commitSettings() }
        }
    }

    // MARK: Helpers

    private func makeWindow<Content: View>(title: String, size: NSSize, autosaveName: String, content: Content) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
