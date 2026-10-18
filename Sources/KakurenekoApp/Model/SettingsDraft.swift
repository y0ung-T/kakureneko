// The settings window edits a LOCAL draft of `KakurenekoSettings` (spec card §9.9): a form bound to
// `snapshot.settings` would be overwritten by every republish.
//
// The draft remembers the `base` it started from. When the coordinator republishes, the draft is REBASED with a
// field-level three-way merge: fields the user edited keep the user's value, every other field follows the new
// snapshot (e.g. a never-pause entry added from the menu, or `launchAtLogin` flipped by its toggle). Committing
// merges the edits onto the latest settings the same way, so a commit never reverts a change made elsewhere.

import KakurenekoKit
import Foundation

/// Field-level three-way merge of `KakurenekoSettings`, done on their JSON form (`KakurenekoJSON`), so it covers every
/// nested field without a hand-written list. Leaves (numbers, strings, arrays — `Set`s encode as sorted arrays)
/// are taken from `local` when the user changed them relative to `base`, else from `remote`.
nonisolated enum SettingsMerge {
    static func merge(base: KakurenekoSettings, local: KakurenekoSettings, remote: KakurenekoSettings) -> KakurenekoSettings {
        if local == base { return remote }
        if remote == base { return local }
        guard let b = jsonObject(base), let l = jsonObject(local), let r = jsonObject(remote) else { return local }
        let merged = mergeValue(base: b, local: l, remote: r)
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let decoded = try? KakurenekoJSON.decode(KakurenekoSettings.self, from: data) else { return local }
        return decoded
    }

    private static func jsonObject(_ settings: KakurenekoSettings) -> Any? {
        guard let data = try? KakurenekoJSON.encode(settings) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func mergeValue(base: Any, local: Any, remote: Any) -> Any {
        if let b = base as? [String: Any], let l = local as? [String: Any], let r = remote as? [String: Any] {
            var out: [String: Any] = [:]
            for key in Set(l.keys).union(r.keys) {
                let bv = b[key]
                switch (l[key], r[key]) {
                case let (lv?, rv?):
                    out[key] = bv.map { mergeValue(base: $0, local: lv, remote: rv) } ?? lv
                case let (lv?, nil):
                    // Remote dropped the key: follow it unless the user changed the value.
                    if let bv, equal(lv, bv) { continue }
                    out[key] = lv
                case let (nil, rv?):
                    // The user's side lacks the key: take remote's value unless it is the unchanged base.
                    if let bv, equal(rv, bv) { continue }
                    out[key] = rv
                case (nil, nil):
                    continue
                }
            }
            return out
        }
        return equal(local, base) ? remote : local
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }
}

/// The settings window's draft.
@Observable
final class SettingsDraft {
    /// The settings the draft was last synchronised with (what the coordinator has).
    private(set) var base: KakurenekoSettings
    /// What the form edits.
    var value: KakurenekoSettings

    init(_ settings: KakurenekoSettings = .default) {
        base = settings
        value = settings
    }

    /// Unsaved edits exist.
    var isDirty: Bool { value != base }

    /// A republished snapshot: keep the user's edits, take everything else from `remote`.
    func rebase(onto remote: KakurenekoSettings) {
        guard remote != base else { return }
        value = SettingsMerge.merge(base: base, local: value, remote: remote)
        base = remote
    }

    /// The settings to send with `updateSettings`: the edits applied onto `latest`, normalized.
    func commitPayload(latest: KakurenekoSettings) -> KakurenekoSettings {
        SettingsMerge.merge(base: base, local: value, remote: latest).normalized()
    }

    /// After `updateSettings(payload)`: the draft is clean and equal to what was sent.
    func markCommitted(_ payload: KakurenekoSettings) {
        base = payload
        value = payload
    }

    /// Throws the edits away.
    func revert() { value = base }
}
