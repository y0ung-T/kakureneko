// KakurenekoPower — live system observers feeding PowerMonitor: IOKit clamshell interest + IORegisterForSystemPower,
// NSWorkspace / ProcessInfo notifications, CoreGraphics display reconfiguration, Darwin power-source notifications.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 (`PowerMonitor`). Brief §7.2, §9.4; R01 §6.2; R08 §8–9.
//
// Swift 6 rules (ARCHITECTURE §5): every closure handed to IOKit/GCD/notify/NotificationCenter is created HERE (a
// nonisolated library) and is `@Sendable`; C callbacks are `@convention(c)` closures without captures that reach a
// `Sendable` box through `Unmanaged`. Registration handles that are not Sendable live in `@unchecked Sendable` boxes
// that are only touched under a `Mutex`.

import AppKit
import CoreGraphics
import KakurenekoKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import notify
import Synchronization

/// What a live observer reports (the monitor turns these into `PowerEvent`s).
enum PowerObservation: Sendable {
    /// `kIOPMMessageClamshellStateChange` with bit 0 (also sent on AC changes; the monitor edge-detects).
    case clamshellMessage(closed: Bool)
    /// `kIOMessageSystemWillSleep`: `allow` calls `IOAllowPowerChange` for this notification.
    case systemWillSleep(allow: @Sendable () -> Void)
    /// `kIOMessageSystemHasPoweredOn`.
    case systemDidWake
    /// `NSWorkspace.willPowerOffNotification`.
    case willPowerOff
    /// `NSWorkspace.sessionDidResignActiveNotification`.
    case sessionResignedActive
    /// `NSWorkspace.sessionDidBecomeActiveNotification`.
    case sessionBecameActive
    /// CoreGraphics display reconfiguration finished.
    case displaysReconfigured
    /// AC/battery/thermal/Low Power Mode changed: take a fresh snapshot.
    case powerConditionsChanged
}

/// Delivers observations to the monitor (called on arbitrary threads/queues).
struct PowerObservationSink: Sendable {
    let deliver: @Sendable (PowerObservation) -> Void
}

/// One live notification source. `start` returns false when the system refused the registration.
protocol PowerObserving: Sendable {
    var name: String { get }
    func start(_ sink: PowerObservationSink) -> Bool
    func stop()
}

// MARK: - IOKit (clamshell + system power)

/// `IOServiceAddInterestNotification(IOPMrootDomain, kIOGeneralInterest)` for lid messages and
/// `IORegisterForSystemPower` for sleep/wake, both on one private serial queue. `kIOMessageCanSystemSleep` is
/// allowed at once; `kIOMessageSystemWillSleep` is forwarded with an `allow` closure (the monitor guarantees it runs).
final class IOKitPowerObserver: PowerObserving {
    /// Everything the C callbacks touch.
    private final class Box: Sendable {
        let sink: PowerObservationSink
        /// The `io_connect_t` returned by `IORegisterForSystemPower` (known only after registration returns).
        let rootConnection = Mutex<io_connect_t>(0)
        init(sink: PowerObservationSink) { self.sink = sink }
    }

    /// Registration handles (non-Sendable C pointers), only touched under `handles`' lock.
    private final class Handles: @unchecked Sendable {
        let box: Box
        var interestPort: IONotificationPortRef?
        var interestNotifier: io_object_t = IO_OBJECT_NULL
        var powerPort: IONotificationPortRef?
        var powerNotifier: io_object_t = IO_OBJECT_NULL
        var rootConnection: io_connect_t = IO_OBJECT_NULL
        init(box: Box) { self.box = box }
    }

    let name = "iokit"
    private let queue = DispatchQueue(label: "com.kakureneko.power.iokit", qos: .userInitiated)
    private let handles = Mutex<Handles?>(nil)
    private let logger: KakurenekoLogger

    init(logger: KakurenekoLogger) { self.logger = logger }

    deinit { stop() }

    func start(_ sink: PowerObservationSink) -> Bool {
        let box = Box(sink: sink)
        let h = Handles(box: box)
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        // Lid: general interest on IOPMrootDomain.
        let interestCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
            guard let refcon, messageType == IOKitMessage.clamshellStateChange else { return }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            let bits = UInt(bitPattern: argument)
            box.sink.deliver(.clamshellMessage(closed: bits & IOKitMessage.clamshellStateBit != 0))
        }
        var interestOK = false
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, queue)
            h.interestPort = port
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(RootDomainKey.serviceClass))
            if root != IO_OBJECT_NULL {
                var notifier = io_object_t(IO_OBJECT_NULL)
                interestOK = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, interestCallback, refcon, &notifier)
                    == KERN_SUCCESS
                h.interestNotifier = notifier
                IOObjectRelease(root)
            }
        }
        if !interestOK { logger.warning("clamshell interest notification unavailable (the 1 Hz poll still runs)") }

        // Sleep/wake: IORegisterForSystemPower.
        let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
            guard let refcon else { return }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            let connection = box.rootConnection.withLock { $0 }
            let notificationID = Int(bitPattern: argument)
            switch messageType {
            case IOKitMessage.canSystemSleep:
                // Idle sleep: never vetoed here (the SleepDisabled flag is the policy).
                _ = IOAllowPowerChange(connection, notificationID)
            case IOKitMessage.systemWillSleep:
                box.sink.deliver(.systemWillSleep(allow: { _ = IOAllowPowerChange(connection, notificationID) }))
            case IOKitMessage.systemHasPoweredOn:
                box.sink.deliver(.systemDidWake)
            default:
                break
            }
        }
        var powerPort: IONotificationPortRef?
        var powerNotifier = io_object_t(IO_OBJECT_NULL)
        let connection = IORegisterForSystemPower(refcon, &powerPort, powerCallback, &powerNotifier)
        let powerOK = connection != IO_OBJECT_NULL && powerPort != nil
        if powerOK, let powerPort {
            box.rootConnection.withLock { $0 = connection }
            h.rootConnection = connection
            h.powerPort = powerPort
            h.powerNotifier = powerNotifier
            IONotificationPortSetDispatchQueue(powerPort, queue)
        } else {
            logger.warning("IORegisterForSystemPower failed (no willSleep/didWake events)")
        }

        let previous = handles.withLock { current -> Handles? in
            defer { current = h }
            return current
        }
        if let previous { teardown(previous) }
        return interestOK || powerOK
    }

    func stop() {
        let current = handles.withLock { h -> Handles? in
            defer { h = nil }
            return h
        }
        if let current { teardown(current) }
    }

    private func teardown(_ h: Handles) {
        if h.powerNotifier != IO_OBJECT_NULL {
            var notifier = h.powerNotifier
            _ = IODeregisterForSystemPower(&notifier)
        }
        if h.rootConnection != IO_OBJECT_NULL { IOServiceClose(h.rootConnection) }
        if let port = h.powerPort { IONotificationPortDestroy(port) }
        if h.interestNotifier != IO_OBJECT_NULL { IOObjectRelease(h.interestNotifier) }
        if let port = h.interestPort { IONotificationPortDestroy(port) }
        // Keep the box (the callbacks' refcon) alive until every callback already queued has run.
        let box = h.box
        queue.async { withExtendedLifetime(box) {} }
    }
}

// MARK: - NSWorkspace / ProcessInfo notifications

/// `NSWorkspace` power-off and fast-user-switching notifications, plus `ProcessInfo` thermal-state and Low Power Mode
/// changes (snapshot triggers). Observers use `queue: nil` (run on the posting thread) and `@Sendable` closures.
final class WorkspaceObserver: PowerObserving {
    private final class Tokens: @unchecked Sendable {
        let workspace: [any NSObjectProtocol]
        let process: [any NSObjectProtocol]
        init(workspace: [any NSObjectProtocol], process: [any NSObjectProtocol]) {
            self.workspace = workspace
            self.process = process
        }
    }

    let name = "workspace"
    private let tokens = Mutex<Tokens?>(nil)

    init() {}

    deinit { stop() }

    func start(_ sink: PowerObservationSink) -> Bool {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let mapping: [(Notification.Name, PowerObservation)] = [
            (NSWorkspace.willPowerOffNotification, .willPowerOff),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        ]
        let workspace = mapping.map { name, observation in
            workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { @Sendable _ in sink.deliver(observation) }
        }
        let processNames: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange]
        let process = processNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable _ in
                sink.deliver(.powerConditionsChanged)
            }
        }
        let new = Tokens(workspace: workspace, process: process)
        let previous = tokens.withLock { t -> Tokens? in
            defer { t = new }
            return t
        }
        if let previous { remove(previous) }
        return true
    }

    func stop() {
        let current = tokens.withLock { t -> Tokens? in
            defer { t = nil }
            return t
        }
        if let current { remove(current) }
    }

    private func remove(_ t: Tokens) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in t.workspace { workspaceCenter.removeObserver(token) }
        for token in t.process { NotificationCenter.default.removeObserver(token) }
    }
}

// MARK: - Display reconfiguration

/// `CGDisplayRegisterReconfigurationCallback`: reports a finished reconfiguration (the monitor re-reads external-display
/// presence and edge-detects). The 1 Hz poll re-checks too, so a missed callback only delays the edge.
final class DisplayReconfigurationObserver: PowerObserving {
    private final class Box: Sendable {
        let sink: PowerObservationSink
        init(sink: PowerObservationSink) { self.sink = sink }
    }

    let name = "displays"
    /// The same function pointer must be passed to register and remove.
    private let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<Box>.fromOpaque(userInfo).takeUnretainedValue().sink.deliver(.displaysReconfigured)
    }
    /// The registered box (kept alive for this observer's lifetime: a callback may still be running after removal).
    private let registered = Mutex<[Box]>([])
    private let active = Mutex<Box?>(nil)

    init() {}

    deinit { stop() }

    func start(_ sink: PowerObservationSink) -> Bool {
        stop()
        let box = Box(sink: sink)
        let status = CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(box).toOpaque())
        guard status == .success else { return false }
        registered.withLock { $0.append(box) }
        active.withLock { $0 = box }
        return true
    }

    func stop() {
        let box = active.withLock { b -> Box? in
            defer { b = nil }
            return b
        }
        if let box {
            CGDisplayRemoveReconfigurationCallback(callback, Unmanaged.passUnretained(box).toOpaque())
        }
    }
}

// MARK: - Darwin notifications (power source, battery, thermal pressure)

/// `notify_register_dispatch` for AC/battery changes and the thermal-pressure level (snapshot triggers).
final class PowerNotifyObserver: PowerObserving {
    let name = "notify"
    private let queue = DispatchQueue(label: "com.kakureneko.power.notify", qos: .utility)
    private let tokens = Mutex<[Int32]>([])
    private let names = [
        PowerNotifyName.powerSource, PowerNotifyName.lowBattery, PowerNotifyName.percentChange,
        PowerNotifyName.thermalPressureLevel,
    ]

    init() {}

    deinit { stop() }

    func start(_ sink: PowerObservationSink) -> Bool {
        stop()
        var registered: [Int32] = []
        for name in names {
            var token: Int32 = 0
            let handler: notify_handler_t = { @Sendable _ in sink.deliver(.powerConditionsChanged) }
            if notify_register_dispatch(name, &token, queue, handler) == NOTIFY_STATUS_OK {
                registered.append(token)
            }
        }
        tokens.withLock { $0 = registered }
        return !registered.isEmpty
    }

    func stop() {
        let current = tokens.withLock { t -> [Int32] in
            defer { t = [] }
            return t
        }
        for token in current { notify_cancel(token) }
    }
}
