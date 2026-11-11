import Foundation

// Human-readable names for libmdr enums.

public extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

public func name(ofEvent e: MDREvent) -> String {
    let names: [UInt32: String] = [
        1: "IDENTITY_CHANGED", 2: "BATTERY_CHANGED", 3: "PLAYBACK_CHANGED", 4: "NOISE_CONTROL_CHANGED",
        5: "SPEAK_TO_CHAT_CHANGED", 6: "LISTENING_MODE_CHANGED", 7: "EQUALIZER_CHANGED",
        8: "PAIRED_DEVICES_CHANGED", 9: "PAIRING_CHANGED", 10: "GENERAL_SETTINGS_CHANGED",
        11: "ASSIGNABLE_CONTROLS_CHANGED", 12: "POWER_CHANGED", 13: "VOICE_GUIDANCE_CHANGED",
        14: "CONNECTION_MODE_CHANGED", 15: "SAFE_LISTENING_CHANGED", 16: "INITIALIZE_COMPLETE",
        17: "SYNC_COMPLETE", 18: "APPLY_COMPLETE", 19: "ALERT", 20: "INTERACTION", 21: "DEVICE_MESSAGE",
        22: "NEED_SYNC", 23: "UNHANDLED", 24: "WEARING_STATUS_CHANGED", 25: "VOICE_ASSISTANT_CHANGED",
    ]
    return names[e] ?? "EVENT_\(e)"
}

public func describe(noiseMode m: MDRNoiseMode) -> String {
    switch m {
    case MDRNoiseMode(MDR_NOISE_MODE_OFF): return "off"
    case MDRNoiseMode(MDR_NOISE_MODE_CANCELLING): return "noise cancelling"
    case MDRNoiseMode(MDR_NOISE_MODE_AMBIENT): return "ambient"
    case MDRNoiseMode(MDR_NOISE_MODE_WIND_NOISE_REDUCTION): return "wind noise reduction"
    default: return "unknown(\(m))"
    }
}

public func describe(codec c: MDRAudioCodec) -> String {
    ["unknown", "SBC", "AAC", "LDAC", "aptX", "aptX HD", "LC3"][safe: Int(c)] ?? (c == 255 ? "other" : "\(c)")
}

public func describe(eqPreset p: MDREqualizerPreset) -> String {
    let names = ["off", "rock", "pop", "jazz", "dance", "EDM", "R&B/hip-hop", "acoustic", "bright", "excited",
                 "mellow", "relaxed", "vocal", "treble", "bass", "speech", "heavy", "clear", "hard", "soft",
                 "gaming", "FPS 1", "FPS 2", "FPS 3", "custom", "user 1", "user 2", "user 3", "user 4", "user 5"]
    return names[safe: Int(p)] ?? "preset \(p)"
}

public func describe(charging c: MDRChargingState) -> String {
    ["", "", " (charging)", " (charged)"][safe: Int(c)] ?? ""
}

public func describe(batteryPart p: MDRBatteryPart) -> String {
    ["", "left", "right", "case"][safe: Int(p)] ?? ""
}
