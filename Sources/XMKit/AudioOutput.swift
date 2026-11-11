import CoreAudio
import Foundation

/// Finding and selecting the Mac's sound output device for a Bluetooth headset.
///
/// Bluetooth audio devices carry the headset's MAC in their CoreAudio UID
/// (e.g. "58-18-62-73-7A-04:output"), which is a stabler match than the name.
public enum AudioOutput {
    public struct Device: Equatable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
    }

    public static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
            == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
            == noErr else { return [] }
        return ids.filter(hasOutputStreams).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// The output device for a Bluetooth address ("AA:BB:…"), matched by UID, then by name.
    public static func device(forBluetoothAddress address: String, name: String?) -> Device? {
        let dashed = address.replacingOccurrences(of: ":", with: "-").uppercased()
        let all = outputDevices()
        return all.first { $0.uid.uppercased().contains(dashed) }
            ?? name.flatMap { n in all.first { $0.name == n } }
    }

    public static var defaultOutputID: AudioDeviceID? { readID(kAudioHardwarePropertyDefaultOutputDevice) }

    /// Makes `device` the default output, and the system (alerts) output too.
    @discardableResult
    public static func makeDefault(_ device: Device) -> Bool {
        writeID(kAudioHardwarePropertyDefaultOutputDevice, device.id)
            && writeID(kAudioHardwarePropertyDefaultSystemOutputDevice, device.id)
    }

    // MARK: CoreAudio plumbing

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func readID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
            == noErr, id != 0 else { return nil }
        return id
    }

    private static func writeID(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
}
