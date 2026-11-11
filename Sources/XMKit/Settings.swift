import Foundation

// Snapshot readers for the Phase 3 settings (EQ, DSEE, Speak-to-Chat, touch controls, power,
// listening mode). Each returns nil when the device doesn't support the setting.

// MARK: Equalizer

public struct EqualizerInfo: Equatable {
    public var preset: MDREqualizerPreset
    /// Presets the device advertised, in its order, with display names.
    public var presets: [(id: MDREqualizerPreset, name: String)]
    public var bands: [Int]
    public var bandFrequencies: [Int] // Hz, same count as `bands` (0 when unknown)
    public var bandRange: ClosedRange<Int>
    public var clearBass: Int?
    public var clearBassRange: ClosedRange<Int>?
    public var dseeAvailable: Bool
    public var dseeEnabled: Bool

    public static func == (a: EqualizerInfo, b: EqualizerInfo) -> Bool {
        a.preset == b.preset && a.presets.map(\.id) == b.presets.map(\.id) && a.bands == b.bands
            && a.bandFrequencies == b.bandFrequencies && a.bandRange == b.bandRange
            && a.clearBass == b.clearBass && a.clearBassRange == b.clearBassRange
            && a.dseeAvailable == b.dseeAvailable && a.dseeEnabled == b.dseeEnabled
    }
}

private func range(_ device: OpaquePointer, min: MDRValue, max: MDRValue, index: UInt32 = 0) -> ClosedRange<Int>? {
    guard let lo = mdrValue(device, min, index: index), let hi = mdrValue(device, max, index: index), lo <= hi
    else { return nil }
    return Int(lo)...Int(hi)
}

public func readEqualizer(_ device: OpaquePointer, _ type: MDRPropertyType) -> EqualizerInfo? {
    var eq = MDREqualizer()
    guard mdrHeadphonesGetEqualizer(device, type, &eq) == OK else { return nil }
    guard eq.available == MDR_YES || eq.dsee_available == MDR_YES else { return nil }

    var bands = [Int32](repeating: 0, count: 32)
    var n = UInt32(bands.count)
    if mdrHeadphonesGetEqualizerBands(device, type, &bands, &n) != OK { n = 0 }
    let bandValues = bands.prefix(Int(n)).map(Int.init)
    let freqs = (0..<UInt32(bandValues.count)).map {
        Int(mdrValue(device, MDRValue(MDR_VALUE_EQUALIZER_BAND_FREQUENCY), index: $0) ?? 0)
    }

    var ids = [MDREqualizerPreset](repeating: 0, count: 64)
    var count = UInt32(ids.count)
    if mdrHeadphonesGetEqualizerPresets(device, &ids, &count) != OK { count = 0 }
    let presets = ids.prefix(Int(count)).enumerated().map { i, id in
        (id: id, name: mdrText(device, MDRText(MDR_TEXT_EQUALIZER_PRESET_NAME), index: UInt32(i))
            ?? describe(eqPreset: id).capitalized)
    }

    let clearBassRange = range(device, min: MDRValue(MDR_VALUE_EQUALIZER_CLEAR_BASS_MIN),
                               max: MDRValue(MDR_VALUE_EQUALIZER_CLEAR_BASS_MAX))
    return EqualizerInfo(
        preset: eq.preset,
        presets: presets,
        bands: bandValues,
        bandFrequencies: freqs,
        bandRange: range(device, min: MDRValue(MDR_VALUE_EQUALIZER_BAND_MIN),
                         max: MDRValue(MDR_VALUE_EQUALIZER_BAND_MAX), index: UInt32(bandValues.count)) ?? -10...10,
        clearBass: clearBassRange == nil ? nil : Int(eq.clear_bass),
        clearBassRange: clearBassRange,
        dseeAvailable: eq.dsee_available == MDR_YES,
        dseeEnabled: eq.dsee_enabled == MDR_YES)
}

public func formatFrequency(_ hz: Int) -> String {
    hz >= 1000 ? (hz % 1000 == 0 ? "\(hz / 1000)k" : String(format: "%.1fk", Double(hz) / 1000)) : "\(hz)"
}

// MARK: Speak-to-Chat

public func readSpeakToChat(_ device: OpaquePointer, _ type: MDRPropertyType) -> MDRSpeakToChat? {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_SPEAK_TO_CHAT)) else { return nil }
    var stc = MDRSpeakToChat()
    return mdrHeadphonesGetSpeakToChat(device, type, &stc) == OK ? stc : nil
}

public func describe(speechSensitivity s: MDRSpeechSensitivity) -> String {
    ["unknown", "auto", "low", "high"][safe: Int(s)] ?? "\(s)"
}

public func describe(speakTimeout t: MDRSpeakTimeout) -> String {
    ["unknown", "short (5 s)", "standard (15 s)", "long (30 s)", "manual"][safe: Int(t)] ?? "\(t)"
}

// MARK: Touch / button controls

public struct ControlInfo: Equatable, Identifiable {
    public var location: MDRAssignableActionKeyLocation
    public var keyType: MDRAssignableActionKeyType
    public var action: MDRAssignableAction
    public var options: [MDRAssignableAction]
    public var id: MDRAssignableActionKeyLocation { location }

    public var asControl: MDRAssignableControl {
        MDRAssignableControl(location: location, type: keyType, action: action)
    }
}

public func readControls(_ device: OpaquePointer, _ type: MDRPropertyType) -> [ControlInfo] {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_ASSIGNABLE_CONTROLS)) else { return [] }
    var controls = [MDRAssignableControl](repeating: MDRAssignableControl(), count: 8)
    var count = UInt32(controls.count)
    guard mdrHeadphonesGetAssignableControls(device, type, &controls, &count) == OK else { return [] }
    return controls.prefix(Int(count)).map { c in
        var options = [MDRAssignableAction](repeating: 0, count: 32)
        var n = UInt32(options.count)
        if mdrHeadphonesGetAssignableControlActions(device, c.location, &options, &n) != OK { n = 0 }
        return ControlInfo(location: c.location, keyType: c.type, action: c.action,
                           options: Array(options.prefix(Int(n))))
    }
}

public func describe(keyLocation k: MDRAssignableActionKeyLocation, type: MDRAssignableActionKeyType) -> String {
    let place = ["?", "Left", "Right", "Custom", "C", "NC/AMB", "NC/Ambient"][safe: Int(k)] ?? "Key \(k)"
    let kind = ["", " touch", " button", " face tap"][safe: Int(type)] ?? ""
    return place + kind
}

public func describe(assignableAction a: MDRAssignableAction) -> String {
    let names = [
        "Not assigned", "Playback", "Noise control", "Noise control / Quick Access", "Track control",
        "Voice assistant", "Google Assistant", "Amazon Alexa", "Tencent Xiaowei", "Cortana", "Quick Access",
        "Volume", "Playback", "Tencent Xiaowei", "Microsoft Teams", "Google Assistant", "Amazon Alexa",
        "Tencent Xiaowei", "Quick Access", "Noise control / Quick Access", "Tencent Xiaowei",
        "Noise control (mic)", "Listening mode / Quick Access", "Noise control / Listening mode", "Chat mix",
        "Custom 1", "Custom 2",
    ]
    return names[safe: Int(a)] ?? "Unknown"
}

// MARK: Power

public struct PowerInfo: Equatable {
    public var raw: MDRPower
    /// Auto power-off choices in minutes; 0 means never.
    public var options: [Int]
    public var minutes: Int { Int(raw.auto_power_off_minutes) }
    public var autoPauseAvailable: Bool

    public static func == (a: PowerInfo, b: PowerInfo) -> Bool {
        a.options == b.options && a.minutes == b.minutes && a.autoPauseAvailable == b.autoPauseAvailable
            && a.raw.wearing_power == b.raw.wearing_power && a.raw.auto_pause == b.raw.auto_pause
    }
}

public func readPower(_ device: OpaquePointer, _ type: MDRPropertyType) -> PowerInfo? {
    var p = MDRPower()
    guard mdrHeadphonesGetPower(device, type, &p) == OK else { return nil }
    let count = Int(mdrValue(device, MDRValue(MDR_VALUE_AUTO_POWER_OFF_OPTION_COUNT)) ?? 0)
    let options = (0..<UInt32(max(0, count))).compactMap {
        mdrValue(device, MDRValue(MDR_VALUE_AUTO_POWER_OFF_OPTION), index: $0).map(Int.init)
    }
    return PowerInfo(raw: p, options: options,
                     autoPauseAvailable: mdrHasFeature(device, MDRFeature(MDR_FEATURE_AUTO_PAUSE)))
}

public func describe(autoOffMinutes m: Int) -> String {
    switch m {
    case 0: return "Never"
    case 60...: return m % 60 == 0 ? "\(m / 60) h" : "\(m) min"
    default: return "\(m) min"
    }
}

// MARK: Listening mode

public struct ListeningInfo: Equatable {
    public var mode: MDRListeningMode
    /// Modes the device supports and currently accepts (Standard always included).
    public var available: [MDRListeningMode]
}

public func readListening(_ device: OpaquePointer, _ type: MDRPropertyType) -> ListeningInfo? {
    guard mdrHasFeature(device, MDRFeature(MDR_FEATURE_LISTENING_MODE)) else { return nil }
    var l = MDRListening()
    guard mdrHeadphonesGetListening(device, type, &l) == OK else { return nil }
    var modes = [MDRListeningMode(MDR_LISTENING_STANDARD)]
    // Background music needs a room size we don't expose yet, so only offer the simple modes.
    for m in [MDR_LISTENING_CINEMA, MDR_LISTENING_VOICE_BOOST, MDR_LISTENING_SOUND_LEAKAGE_REDUCTION] {
        var status = MDRListeningStatus()
        if mdrHeadphonesGetListeningStatus(device, MDRListeningMode(m), &status) == OK, status.available == MDR_YES {
            modes.append(MDRListeningMode(m))
        }
    }
    return ListeningInfo(mode: l.mode, available: modes)
}

public func describe(listeningMode m: MDRListeningMode) -> String {
    ["Standard", "Background music", "Cinema", "Voice boost", "Sound leakage reduction"][safe: Int(m)] ?? "\(m)"
}

// MARK: Composite writes (shared by the CLI and the app)

private let customPresets: Set<MDREqualizerPreset> = [
    MDREqualizerPreset(MDR_EQ_CUSTOM), MDREqualizerPreset(MDR_EQ_USER_1), MDREqualizerPreset(MDR_EQ_USER_2),
    MDREqualizerPreset(MDR_EQ_USER_3), MDREqualizerPreset(MDR_EQ_USER_4), MDREqualizerPreset(MDR_EQ_USER_5),
]

/// Stages a full band layout. Like Sony's app, editing bands while a fixed preset (e.g. Heavy) is active
/// switches to the Custom preset first, when the device offers one.
public func stageEqualizerBands(_ device: OpaquePointer, _ bands: [Int]) throws {
    guard let eq = readEqualizer(device, PROPERTY_DESIRED) else { throw XMError("equalizer unavailable") }
    let custom = MDREqualizerPreset(MDR_EQ_CUSTOM)
    if !customPresets.contains(eq.preset), eq.presets.contains(where: { $0.id == custom }) {
        try check(mdrHeadphonesSetEqualizerPreset(device, custom), "SetEqualizerPreset(custom)")
    }
    let values = bands.map { Int32(min(max($0, eq.bandRange.lowerBound), eq.bandRange.upperBound)) }
    try check(mdrHeadphonesSetEqualizerBands(device, values, UInt32(values.count)), "SetEqualizerBands")
}

/// Stages one key's action; libmdr requires the complete key list on every write.
public func stageControl(_ device: OpaquePointer, location: MDRAssignableActionKeyLocation,
                         action: MDRAssignableAction) throws {
    var controls = readControls(device, PROPERTY_DESIRED)
    guard let i = controls.firstIndex(where: { $0.location == location }) else {
        throw XMError("no such control")
    }
    guard controls[i].options.contains(action) else { throw XMError("that key doesn't offer this action") }
    controls[i].action = action
    let raw = controls.map(\.asControl)
    try check(mdrHeadphonesSetAssignableControls(device, raw, UInt32(raw.count)), "SetAssignableControls")
}
