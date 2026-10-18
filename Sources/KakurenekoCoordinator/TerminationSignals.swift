// SIGTERM/INT/HUP/QUIT belong to the coordinator (ARCHITECTURE §9.8 start step 1, §11 item 19): thaw, then
// disarm, then exit — synchronously, from a non-async dispatch-source handler. Only the live app installs them
// (`KakurenekoServices.handlesTerminationSignals`); a test process never does.

import Darwin
import KakurenekoKit
import Foundation

/// Retains the installed sources (a cancelled/deallocated source stops delivering).
final class TerminationSignalSources: @unchecked Sendable {
    // @unchecked: written once at creation, then only read; DispatchSource objects are thread-safe.
    let sources: [any DispatchSourceSignal]

    init(sources: [any DispatchSourceSignal]) { self.sources = sources }

    var count: Int { sources.count }

    func cancelAll() { for source in sources { source.cancel() } }
}

enum TerminationSignals {
    /// The signals routed to the synchronous shutdown path.
    static let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

    /// Ignores the default disposition and installs one dispatch source per signal. The handler closure is
    /// created HERE (nonisolated library code, `@Sendable`), never in the MainActor app target (R08 pitfall 1).
    static func install(pausing: any AppPausing, power: any PowerControlling, logger: KakurenekoLogger) -> TerminationSignalSources {
        let queue = DispatchQueue(label: "com.kakureneko.coordinator.termination")
        let sources: [any DispatchSourceSignal] = signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { @Sendable in
                logger.notice("signal \(number): thawing, disarming, exiting")
                terminate(pausing: pausing, power: power, logger: logger, context: "signal \(number)")
                exit(0)
            }
            source.resume()
            return source
        }
        return TerminationSignalSources(sources: sources)
    }

    /// Thaw, then disarm (brief §7.3 order), synchronously — the signal handler, the app's quit watchdog and
    /// `applicationWillTerminate` all end here.
    static func terminate(pausing: any AppPausing, power: any PowerControlling, logger: KakurenekoLogger, context: String) {
        let thawed = pausing.thawAllSynchronously(reason: .appQuitting)
        let clear = power.disarmSynchronously(timeout: .seconds(2))
        logger.notice("\(context): thawed \(thawed) process(es), flag clear: \(clear)")
    }
}
