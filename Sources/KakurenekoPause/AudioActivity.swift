import CoreAudio
import Darwin
import Foundation

/// Rule P-F: which processes are playing or recording audio right now, from the public CoreAudio process objects
/// (macOS 14.2+; readable without any permission prompt — R06 §1.1 "Audio", `audio.swift`).
///
/// One `kAudioHardwarePropertyProcessObjectList` read per evaluation, then `kAudioProcessPropertyPID` and
/// `kAudioProcessPropertyIsRunningOutput`/`…Input` per audio client (a few dozen), instead of a
/// `kAudioHardwarePropertyTranslatePIDToProcessObject` call for each of ~400 group members.
struct AudioActivityProbe: Sendable {
    init() {}

    /// Pids with running audio output or input. Empty when CoreAudio is unavailable.
    func activePIDs() -> Set<pid_t> {
        var result: Set<pid_t> = []
        for object in processObjects() where isRunning(object) {
            if let pid = pid(of: object) { result.insert(pid) }
        }
        return result
    }

    /// The process object for `pid` (`kAudioHardwarePropertyTranslatePIDToProcessObject`), if CoreAudio knows it.
    func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    /// Whether `pid` currently plays or records audio.
    func isActive(pid: pid_t) -> Bool {
        processObject(for: pid).map(isRunning) ?? false
    }

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func isRunning(_ object: AudioObjectID) -> Bool {
        (uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            || (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
