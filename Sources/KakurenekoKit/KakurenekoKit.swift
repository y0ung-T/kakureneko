// KakurenekoKit — the binding contract layer of Kakureneko.
//
// OWNERSHIP: architect only. Implementation agents never edit files under Sources/KakurenekoKit.
// If you need a contract change, work around it locally in your own module (internal types,
// extensions) and REPORT it in your final summary (see docs/ARCHITECTURE.md §"Contract changes").
//
// What lives here:
//   * Foundation/   paths, identifiers, clock, logging, dry-run policy, atomic files, JSON, broadcaster
//   * Model/        every value type that crosses a module boundary (Sendable, Codable where persisted)
//   * Services/     cross-module service protocols the coordinator composes
//   * SideEffects/  injectable system-mutating protocols + dry-run/switching implementations
//   * Testing/      fakes usable from any test target (and SwiftUI previews)
//
// Isolation: this module is nonisolated (no default actor isolation). Every public type is
// Sendable. Stateful helpers are `final class … : Sendable` guarded by `Mutex` (Synchronization).
// There is no global mutable state.

import Foundation

/// Version constants shared by the app, the helpers and the persisted files.
public enum KakurenekoKit {
    /// Bumped whenever a public contract in this module changes incompatibly.
    public static let contractVersion = 2
    /// Marketing version of this build (also written to the install manifest as `helperVersion`).
    public static let marketingVersion = "0.1.0"
}
