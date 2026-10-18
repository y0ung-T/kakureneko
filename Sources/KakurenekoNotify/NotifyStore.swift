import KakurenekoCloud
import KakurenekoKit
import Foundation

/// `notify-state.json` (0600): this Mac's identity, the iCloud change token, the command replay cache, the
/// iPhones seen in iCloud, the alerts this Mac saved (for pruning) and the last delivery / command times.
struct NotifyPersistentState: Sendable, Hashable, Codable {
    /// 2: native notifications (v1 held the ntfy cursor and nonces; its fields are ignored).
    static let currentVersion = 2
    /// Saved alert ids kept for pruning (oldest dropped beyond this).
    static let maximumSavedAlerts = 500

    /// One alert this Mac saved to iCloud.
    struct SavedAlert: Sendable, Hashable, Codable {
        var id: String
        var createdAt: Date
    }

    var version: Int = NotifyPersistentState.currentVersion
    /// `MacStatus.macID`, what commands target: derived from the machine in the app (`MachineIdentity`), random
    /// in tests.
    var macID: String = UUID().uuidString
    /// Zone change token of the last complete fetch.
    var changeToken: CloudChangeToken?
    /// Command id → expiry: a command id is executed at most once (kept until it expires).
    var seenCommands: [String: Date] = [:]
    /// iPhones running the Kakureneko app (from their `PhoneDevice` records), by device id.
    var phones: [String: PhoneDevice] = [:]
    var savedAlerts: [SavedAlert] = []
    var lastDeliveredAt: Date?
    var lastCommandAt: Date?
    /// Last time old records were deleted from iCloud.
    var lastPrunedAt: Date?
    /// The Apple Account the iCloud state above belongs to (`CloudStore.accountTag`): another one resets it.
    var accountTag: String?
    /// "iPhone alerts off" (or Uninstall) could not reach iCloud: this Mac's records are removed once it can.
    var pendingCloudRemoval = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, macID, changeToken, seenCommands, phones, savedAlerts, lastDeliveredAt, lastCommandAt, lastPrunedAt
        case accountTag, pendingCloudRemoval
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotifyPersistentState()
        version = c.tolerantDecode(Int.self, forKey: .version, default: NotifyPersistentState.currentVersion)
        let id = c.tolerantDecode(String.self, forKey: .macID, default: "")
        macID = UUID(uuidString: id) != nil ? id : d.macID
        changeToken = c.tolerantDecodeIfPresent(CloudChangeToken.self, forKey: .changeToken)
        seenCommands = c.tolerantDecode([String: Date].self, forKey: .seenCommands, default: [:])
        phones = c.tolerantDecode([String: PhoneDevice].self, forKey: .phones, default: [:])
        savedAlerts = c.tolerantDecode([SavedAlert].self, forKey: .savedAlerts, default: [])
        lastDeliveredAt = c.tolerantDecodeIfPresent(Date.self, forKey: .lastDeliveredAt)
        lastCommandAt = c.tolerantDecodeIfPresent(Date.self, forKey: .lastCommandAt)
        lastPrunedAt = c.tolerantDecodeIfPresent(Date.self, forKey: .lastPrunedAt)
        accountTag = c.tolerantDecodeIfPresent(String.self, forKey: .accountTag)
        pendingCloudRemoval = c.tolerantDecode(Bool.self, forKey: .pendingCloudRemoval, default: false)
    }

    /// Another Apple Account: everything that belonged to the previous one goes (this Mac's id stays).
    mutating func resetForAccount(_ tag: String) {
        accountTag = tag
        changeToken = nil
        seenCommands = [:]
        phones = [:]
        savedAlerts = []
        lastPrunedAt = nil
        pendingCloudRemoval = false
    }

    /// Forgets replay entries whose command can no longer run.
    mutating func pruneSeenCommands(now: Date) {
        seenCommands = seenCommands.filter { $0.value > now }
    }

    mutating func noteSavedAlert(_ id: String, createdAt: Date) {
        guard !savedAlerts.contains(where: { $0.id == id }) else { return }
        savedAlerts.append(SavedAlert(id: id, createdAt: createdAt))
        if savedAlerts.count > Self.maximumSavedAlerts { savedAlerts.removeFirst(savedAlerts.count - Self.maximumSavedAlerts) }
    }
}

/// Atomic, tolerant persistence of Notify's files. Corrupt files load as empty (never crash).
struct NotifyStore: Sendable {
    let paths: Paths

    // MARK: notify-state.json (0600)

    func loadState() -> NotifyPersistentState {
        guard let data = try? AtomicFile.readIfExists(paths.notifyStateFile),
              let state = try? KakurenekoJSON.decode(NotifyPersistentState.self, from: data) else { return NotifyPersistentState() }
        return state
    }

    func saveState(_ state: NotifyPersistentState) throws {
        try AtomicFile.write(KakurenekoJSON.encode(state), to: paths.notifyStateFile, permissions: 0o600, followSymlinks: false)
    }

    // MARK: outbox.json (0600)

    func loadOutbox() -> [OutboxItem] {
        guard let data = try? AtomicFile.readIfExists(paths.outboxFile),
              let file = try? KakurenekoJSON.decode(OutboxFile.self, from: data) else { return [] }
        return file.items
    }

    func saveOutbox(_ items: [OutboxItem]) throws {
        try AtomicFile.write(KakurenekoJSON.encode(OutboxFile(items: items)), to: paths.outboxFile, permissions: 0o600, followSymlinks: false)
    }

    // MARK: Legacy

    /// Deletes the ntfy `secrets.json` of earlier versions (topics and HMAC key that are no longer used).
    /// True when a file was removed.
    @discardableResult
    func removeLegacySecrets() -> Bool {
        do {
            try FileManager.default.removeItem(at: paths.legacySecretsFile)
            return true
        } catch {
            return false
        }
    }
}
