// KakurenekoPower — LidSimulation: a developer tool that lets a dry-run walk the closed-lid flow on a Mac whose lid is
// really open (or held open by an external display): pausing decisions, countdowns, "would sleep".
// OWNER: integrator. ARCHITECTURE §6 (dry-run policy) and §10.
//
// Safety: honoured ONLY when the environment forces dry-run (`KAKURENEKO_DRY_RUN=1`, which no settings toggle can turn
// off for the process lifetime), so a simulated lid can never make a real app pause, arm or sleep anything. The
// control file is read on every lid/display/input read (1 Hz poll), so it can be flipped while the app runs:
//
//     echo closed > /tmp/lid    # Kakureneko now sees: lid closed, no external display, no input since this write
//     echo open   > /tmp/lid    # (or delete it) real readings again
//     KAKURENEKO_DRY_RUN=1 KAKURENEKO_HOME=/tmp/kakureneko-dev KAKURENEKO_SIMULATE_LID=/tmp/lid build/Kakureneko.app/Contents/MacOS/Kakureneko

import KakurenekoKit
import Foundation

/// Simulated lid state read from a control file (content `closed` → closed; anything else or no file → real readings).
public final class LidSimulation: Sendable {
    /// The control file (absolute).
    public let controlFile: URL
    private let clock: any KakurenekoClock

    public init(controlFile: URL, clock: any KakurenekoClock = SystemClock()) {
        self.controlFile = controlFile
        self.clock = clock
    }

    /// `KAKURENEKO_SIMULATE_LID=<absolute path>`, honoured only when `KAKURENEKO_DRY_RUN` is truthy in the same
    /// environment. nil otherwise (production never simulates).
    public static func fromEnvironment(_ environment: [String: String]) -> LidSimulation? {
        guard DryRunPolicy.fromEnvironment(environment).isEnabled,
              let path = environment[KakurenekoEnvironment.simulateLid], path.hasPrefix("/") else { return nil }
        return LidSimulation(controlFile: URL(filePath: path, directoryHint: .notDirectory))
    }

    /// The control file's modification time while it says `closed`; nil while the real readings apply.
    func closedSince() -> Date? {
        guard let data = try? Data(contentsOf: controlFile), data.count <= 64,
              String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "closed",
              let modified = (try? FileManager.default.attributesOfItem(atPath: controlFile.path(percentEncoded: false)))?[.modificationDate] as? Date
        else { return nil }
        return modified
    }

    /// True while the control file says `closed`.
    public var isSimulatingClosed: Bool { closedSince() != nil }

    func clamshellClosed(real: Bool?) -> Bool? {
        isSimulatingClosed ? true : real
    }

    func externalDisplayConnected(real: Bool) -> Bool {
        isSimulatingClosed ? false : real
    }

    /// While closed: the last input happened a day before the control file was written, so the user is away and no
    /// closed-lid activity is ever seen, even when the REAL lid was already closed (clamshell mode: the monitor's
    /// `lidClosedSince` then predates the control file).
    func secondsSinceUserInput(real: TimeInterval?) -> TimeInterval? {
        guard let since = closedSince() else { return real }
        return max(0, clock.now().timeIntervalSince(since)) + Self.simulatedIdleBeforeClose
    }

    /// How long before the control file was written the simulated last input happened.
    static let simulatedIdleBeforeClose: TimeInterval = 86_400
}

// MARK: - Simulated readers (wrap the live ones)

struct SimulatedRootDomain: RootDomainReading {
    let base: any RootDomainReading
    let simulation: LidSimulation

    func sleepDisabled() -> Bool? { base.sleepDisabled() }
    func clamshellClosed() -> Bool? { simulation.clamshellClosed(real: base.clamshellClosed()) }
}

struct SimulatedDisplayReader: ExternalDisplayReading {
    let base: any ExternalDisplayReading
    let simulation: LidSimulation

    func externalDisplayConnected() -> Bool { simulation.externalDisplayConnected(real: base.externalDisplayConnected()) }
}

struct SimulatedInputReader: UserInputIdleReading {
    let base: any UserInputIdleReading
    let simulation: LidSimulation

    func secondsSinceUserInput() -> TimeInterval? { simulation.secondsSinceUserInput(real: base.secondsSinceUserInput()) }
}
