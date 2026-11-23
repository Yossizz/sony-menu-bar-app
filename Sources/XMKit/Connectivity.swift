import Foundation

// Readers for multipoint (devices the headphones are paired with), playback / now playing,
// and wearing status.

// MARK: Multipoint

/// A source device as the *headphones* see it (phone, Mac, tablet…), not a Mac Bluetooth peer.
public struct HeadsetPeer: Equatable, Identifiable {
    public let name: String
    /// "AA:BB:CC:DD:EE:FF" as reported by the headphones; used as the command target.
    public let address: String
    public let connected: Bool
    /// The device whose audio the headphones are currently playing.
    public let isPlaybackSource: Bool
    public var id: String { address }
}

public func readPeers(_ device: OpaquePointer) -> [HeadsetPeer] {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_PAIRED_DEVICE_MANAGEMENT)) else { return [] }
    var list = [MDRPairedDevice](repeating: MDRPairedDevice(), count: 16)
    var count = UInt32(list.count)
    guard mdrHeadphonesGetPairedDevices(device, &list, &count) == OK else { return [] }
    return list.prefix(Int(count)).map { d in
        var d = d
        let name = withUnsafeBytes(of: &d.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let mac = withUnsafeBytes(of: &d.macAddress) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return HeadsetPeer(name: name.isEmpty ? mac : name, address: mac,
                           connected: d.connected == MDR_YES, isPlaybackSource: d.playback_device == MDR_YES)
    }
}

/// Stages a multipoint command (connect / disconnect / play from / unpair) for one peer.
public func stagePeerCommand(_ device: OpaquePointer, _ command: MDRPairedDeviceCommand, address: String) throws {
    try address.withCString { ptr in
        var action = MDRPairedDeviceAction(command: command, device_id: ptr,
                                           device_id_size: UInt32(address.utf8.count))
        try check(mdrHeadphonesSetPairedDevice(device, &action), "SetPairedDevice")
    }
}

/// nil when the device can't pin playback to one source; otherwise whether it may switch on its own.
public func readAutoSourceSwitch(_ device: OpaquePointer, _ type: MDRPropertyType) -> Bool? {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_SOURCE_SWITCH_CONTROL)) else { return nil }
    var enabled = MDR_YES
    return mdrHeadphonesGetSourceSwitchControl(device, type, &enabled) == OK ? enabled == MDR_YES : nil
}

// MARK: Playback / now playing

public struct NowPlaying: Equatable {
    public var status: MDRPlaybackStatus
    public var title: String?
    public var artist: String?
    public var album: String?
    public var volume: Int?
    public var volumeRange: ClosedRange<Int>?

    public var isPlaying: Bool { status == MDRPlaybackStatus(MDR_PLAYBACK_PLAYING) }
    public var hasTrack: Bool { title != nil || artist != nil }
}

public func readNowPlaying(_ device: OpaquePointer, _ type: MDRPropertyType) -> NowPlaying? {
    let control = mdrHasFeature(device, MDRFeature(MDR_FEATURE_PLAYBACK_CONTROL))
    let metadata = mdrHasFeature(device, MDRFeature(MDR_FEATURE_PLAYBACK_METADATA))
    let volume = mdrHasFeature(device, MDRFeature(MDR_FEATURE_PLAYBACK_VOLUME))
    guard control || metadata || volume else { return nil }
    var p = MDRPlayback()
    guard mdrHeadphonesGetPlayback(device, type, &p) == OK else { return nil }
    var range: ClosedRange<Int>?
    if volume, let lo = mdrValue(device, MDRValue(MDR_VALUE_PLAYBACK_VOLUME_MIN)),
       let hi = mdrValue(device, MDRValue(MDR_VALUE_PLAYBACK_VOLUME_MAX)), lo < hi {
        range = Int(lo)...Int(hi)
    }
    return NowPlaying(
        status: p.status,
        title: metadata ? mdrText(device, MDRText(MDR_TEXT_TRACK_TITLE)) : nil,
        artist: metadata ? mdrText(device, MDRText(MDR_TEXT_TRACK_ARTIST)) : nil,
        album: metadata ? mdrText(device, MDRText(MDR_TEXT_TRACK_ALBUM)) : nil,
        volume: range == nil ? nil : Int(p.volume),
        volumeRange: range)
}

public func stagePlayback(_ device: OpaquePointer, _ action: MDRPlaybackAction) throws {
    var command = MDRPlaybackCommand(action: action)
    try check(mdrHeadphonesSendPlaybackCommand(device, &command), "SendPlaybackCommand")
}

// MARK: Wearing status

public enum Wearing: Equatable {
    case worn, leftOut, rightOut, bothOut

    /// How many earbuds are out of the ears.
    public var removedCount: Int {
        switch self {
        case .worn: return 0
        case .leftOut, .rightOut: return 1
        case .bothOut: return 2
        }
    }
}

public func readWearing(_ device: OpaquePointer) -> Wearing? {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_WEARING_STATUS)) else { return nil }
    var s = MDRWearingStatus(MDR_WEARING_STATUS_UNKNOWN)
    guard mdrHeadphonesGetWearingStatus(device, &s) == OK else { return nil }
    switch s {
    case MDRWearingStatus(MDR_WEARING_STATUS_WORN): return .worn
    case MDRWearingStatus(MDR_WEARING_STATUS_LEFT_REMOVED): return .leftOut
    case MDRWearingStatus(MDR_WEARING_STATUS_RIGHT_REMOVED): return .rightOut
    case MDRWearingStatus(MDR_WEARING_STATUS_REMOVED): return .bothOut
    default: return nil
    }
}
