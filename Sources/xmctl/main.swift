import Foundation
import XMKit

// xmctl — Phase 0 spike: prove we can talk to a WH-1000XM6 (MDR protocol V2) from Swift.

Responsibility.disclaimIfNeeded()

let usage = """
usage:
  xmctl list                                   paired Bluetooth devices
  xmctl status <MAC> [options]                 model, firmware, battery, noise control, EQ
  xmctl anc <MAC> off|nc|ambient [options]     set noise control, then read it back
      --level N      ambient level (ambient mode)
      --voice        focus on voice (ambient mode)

options:
  --v1 | --v2        force protocol (default: try V2, then V1)
  --trace            print every TX/RX frame as hex on stderr
  -v                 verbose progress on stderr

MAC looks like AA:BB:CC:DD:EE:FF (see `xmctl list`).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

verbose = takeFlag("-v")
let trace = takeFlag("--trace")
let forceV1 = takeFlag("--v1")
let forceV2 = takeFlag("--v2")
let levelArg = takeOption("--level")
let voice = takeFlag("--voice")
let protocolChoice: Session.ProtocolChoice = forceV1 ? .v1 : (forceV2 ? .v2 : .auto)

guard let command = args.first else { print(usage); exit(2) }

func printNoiseControl(_ s: Session, _ type: MDRPropertyType = MDRPropertyType(MDR_PROPERTY_CURRENT)) {
    guard let dev = s.device else { return }
    var nc = MDRNoiseControl()
    guard mdrHeadphonesGetNoiseControl(dev, type, &nc) == OK else {
        print("noise control: unavailable"); return
    }
    var line = "noise control: \(describe(noiseMode: nc.mode))"
    if nc.mode == MDRNoiseMode(MDR_NOISE_MODE_AMBIENT) {
        line += ", level \(nc.ambient_level)"
        if nc.focus_on_voice == MDRBoolean(MDR_TRUE) { line += ", focus on voice" }
        if nc.adaptive_ambient == MDRBoolean(MDR_TRUE) { line += ", auto ambient" }
    }
    print(line)
}

func printStatus(_ s: Session) {
    guard let dev = s.device else { return }
    var model = MDRModel()
    _ = mdrHeadphonesGetModel(dev, &model)
    print("model:         \(s.text(MDRText(MDR_TEXT_MODEL_NAME)) ?? "?")")
    print("firmware:      \(s.text(MDRText(MDR_TEXT_FIRMWARE_VERSION)) ?? "?")")
    print("protocol:      V\(s.protocolVersion)")
    print("codec:         \(describe(codec: model.audio_codec))")

    var batteries = [MDRBattery](repeating: MDRBattery(), count: 4)
    var count = UInt32(batteries.count)
    if mdrHeadphonesGetBatteries(dev, &batteries, &count) == OK, count > 0 {
        let parts = ["", "left ", "right ", "case "]
        let text = batteries.prefix(Int(count)).map {
            "\(parts[safe: Int($0.part)] ?? "")\($0.level_percent)%\(describe(charging: $0.charging))"
        }
        print("battery:       " + text.joined(separator: ", "))
    } else {
        print("battery:       unavailable")
    }

    printNoiseControl(s)

    var eq = MDREqualizer()
    if mdrHeadphonesGetEqualizer(dev, MDRPropertyType(MDR_PROPERTY_CURRENT), &eq) == OK,
       eq.available == MDRBoolean(MDR_TRUE) {
        var bands = [Int32](repeating: 0, count: 16)
        var n = UInt32(bands.count)
        let shown = Int(min(n, eq.band_count > 0 ? eq.band_count : n))
        let bandText = mdrHeadphonesGetEqualizerBands(dev, MDRPropertyType(MDR_PROPERTY_CURRENT), &bands, &n) == OK
            ? bands.prefix(shown).map(String.init).joined(separator: " ") : "?"
        print("equalizer:     \(describe(eqPreset: eq.preset)), clear bass \(eq.clear_bass), "
            + "\(eq.band_count) bands [\(bandText)]")
        if eq.dsee_available == MDRBoolean(MDR_TRUE) {
            print("DSEE:          \(eq.dsee_enabled == MDRBoolean(MDR_TRUE) ? "on" : "off")")
        }
    }

    let features: [(MDRFeature, String)] = [
        (MDRFeature(MDR_FEATURE_NOISE_CANCELLING), "noise cancelling"),
        (MDRFeature(MDR_FEATURE_AMBIENT_SOUND), "ambient"),
        (MDRFeature(MDR_FEATURE_ADAPTIVE_AMBIENT_SOUND), "auto ambient"),
        (MDRFeature(MDR_FEATURE_SPEAK_TO_CHAT), "speak-to-chat"),
        (MDRFeature(MDR_FEATURE_LISTENING_MODE), "listening mode"),
        (MDRFeature(MDR_FEATURE_EQUALIZER), "equalizer"),
        (MDRFeature(MDR_FEATURE_DSEE), "DSEE"),
        (MDRFeature(MDR_FEATURE_PAIRED_DEVICE_MANAGEMENT), "multipoint"),
        (MDRFeature(MDR_FEATURE_ASSIGNABLE_CONTROLS), "assignable controls"),
        (MDRFeature(MDR_FEATURE_AUTO_POWER_OFF), "auto power off"),
        (MDRFeature(MDR_FEATURE_WEARING_DETECTION), "wearing detection"),
        (MDRFeature(MDR_FEATURE_VOICE_GUIDANCE), "voice guidance"),
    ]
    print("features:      " + features.filter { s.feature($0.0) }.map(\.1).joined(separator: ", "))
}

// MARK: Commands

func openSession(address: String) -> Session {
    let s = Session()
    s.onEvent = { event in
        // UNHANDLED = a report libmdr doesn't model; only interesting when tracing raw frames.
        if event != MDREvent(MDR_EVENT_UNHANDLED) || trace { log("event \(name(ofEvent: event))") }
    }
    do {
        try s.connect(address: address, protocol: protocolChoice)
        try s.start(trace: trace)
        try s.sync()
    } catch {
        fail("\(error)")
    }
    return s
}

func requireAddress() -> String {
    guard args.count >= 2 else { fail("missing <MAC>\n\n\(usage)") }
    return normalizeAddress(args[1])
}

switch command {
case "list":
    let devices = pairedDevices()
    if devices.isEmpty { print("no paired devices") }
    for d in devices { print("\(d.address)  \(d.isConnected ? "connected    " : "not connected")  \(d.name)") }

case "status":
    let s = openSession(address: requireAddress())
    try? s.drain(0.5) // pick up any reports that trail initialization
    printStatus(s)

case "anc":
    let address = requireAddress()
    guard args.count >= 3 else { fail("missing mode (off|nc|ambient)") }
    let mode: MDRNoiseMode
    switch args[2] {
    case "off": mode = MDRNoiseMode(MDR_NOISE_MODE_OFF)
    case "nc": mode = MDRNoiseMode(MDR_NOISE_MODE_CANCELLING)
    case "ambient": mode = MDRNoiseMode(MDR_NOISE_MODE_AMBIENT)
    default: fail("mode must be off, nc or ambient")
    }
    let s = openSession(address: address)
    guard let dev = s.device else { fail("no device") }
    print("before → ", terminator: ""); printNoiseControl(s)

    var nc = MDRNoiseControl()
    do {
        try check(mdrHeadphonesGetNoiseControl(dev, MDRPropertyType(MDR_PROPERTY_DESIRED), &nc), "GetNoiseControl")
        nc.mode = mode
        if let levelArg {
            guard let level = UInt32(levelArg) else { fail("--level must be a number") }
            if let lo = s.value(MDRValue(MDR_VALUE_AMBIENT_LEVEL_MIN)),
               let hi = s.value(MDRValue(MDR_VALUE_AMBIENT_LEVEL_MAX)),
               !(Int(lo)...Int(hi)).contains(Int(level)) {
                fail("--level must be within \(lo)...\(hi) on this device")
            }
            nc.ambient_level = level
            nc.adaptive_ambient = MDRBoolean(MDR_FALSE)
        }
        if mode == MDRNoiseMode(MDR_NOISE_MODE_AMBIENT) {
            nc.focus_on_voice = MDRBoolean(voice ? MDR_TRUE : MDR_FALSE)
        }
        try check(mdrHeadphonesSetNoiseControl(dev, &nc), "SetNoiseControl")
        try s.commit()
        try s.drain(1.0) // device reports the new state after ACKing the write
    } catch { fail("\(error)") }
    print("after  → ", terminator: ""); printNoiseControl(s)

default:
    print(usage)
    exit(2)
}
