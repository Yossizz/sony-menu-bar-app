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
  xmctl eq <MAC> <preset-id>                   pick an EQ preset (ids are listed by `status`)
  xmctl eqbands <MAC> v1,v2,…                  set all EQ bands (switches to Custom)
  xmctl control <MAC> <key> <action>           touch control (ids are listed by `status`)
  xmctl dsee <MAC> on|off                      DSEE upscaling
  xmctl stc <MAC> on|off                       Speak-to-Chat
  xmctl autooff <MAC> <minutes>                auto power-off (0 = never)

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

    printSettings(dev)

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

func printSettings(_ dev: OpaquePointer, _ type: MDRPropertyType = PROPERTY_CURRENT) {
    if let eq = readEqualizer(dev, type) {
        let name = eq.presets.first { $0.id == eq.preset }?.name ?? describe(eqPreset: eq.preset)
        print("equalizer:     \(name) (\(eq.preset))")
        let bands = zip(eq.bandFrequencies, eq.bands).map { "\(formatFrequency($0)):\($1)" }
        print("  bands:       [\(bands.joined(separator: " "))]  range \(eq.bandRange)")
        if let cb = eq.clearBass, let r = eq.clearBassRange { print("  clear bass:  \(cb)  range \(r)") }
        print("  presets:     " + eq.presets.map { "\($0.name)(\($0.id))" }.joined(separator: ", "))
        if eq.dseeAvailable { print("DSEE:          \(eq.dseeEnabled ? "on" : "off")") }
    }
    if let stc = readSpeakToChat(dev, type) {
        print("speak-to-chat: \(stc.enabled == MDR_YES ? "on" : "off"), sensitivity "
            + "\(describe(speechSensitivity: stc.sensitivity)), ends after \(describe(speakTimeout: stc.timeout))")
    }
    if let l = readListening(dev, type) {
        print("listening:     \(describe(listeningMode: l.mode)); available: "
            + l.available.map { describe(listeningMode: $0) }.joined(separator: ", "))
    }
    for c in readControls(dev, type) {
        print("control:       \(describe(keyLocation: c.location, type: c.keyType)) → "
            + "\(describe(assignableAction: c.action)) (\(c.action)); options: "
            + c.options.map { "\(describe(assignableAction: $0))(\($0))" }.joined(separator: ", "))
    }
    if let p = readPower(dev, type) {
        print("auto off:      \(describe(autoOffMinutes: p.minutes)); options: "
            + p.options.map { describe(autoOffMinutes: $0) }.joined(separator: ", ")
            + "; wearing power \(p.raw.wearing_power), auto pause "
            + (p.autoPauseAvailable ? (p.raw.auto_pause == MDR_YES ? "on" : "off") : "n/a"))
    }
}

/// Connects, applies `change` (staging writes), commits, and prints settings before and after.
func applySetting(_ change: (OpaquePointer) throws -> Void) {
    let s = openSession(address: requireAddress())
    guard let dev = s.device else { fail("no device") }
    print("— before"); printSettings(dev)
    do {
        try change(dev)
        try s.commit()
        try s.drain(1.5)
    } catch { fail("\(error)") }
    print("— after"); printSettings(dev)
}

func argument(_ i: Int, _ what: String) -> String {
    guard args.count > i else { fail("missing \(what)\n\n\(usage)") }
    return args[i]
}

func parseOnOff(_ s: String) -> MDRBoolean {
    switch s { case "on": return MDR_YES; case "off": return MDR_NO; default: fail("expected on or off") }
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

case "eq":
    let preset = argument(2, "preset id (see `status`)")
    guard let id = UInt32(preset) else { fail("preset must be a number from the presets list") }
    applySetting { try check(mdrHeadphonesSetEqualizerPreset($0, MDREqualizerPreset(id)), "SetEqualizerPreset") }

case "output":
    // Read-only: which CoreAudio output belongs to each connected headset, and which is the default.
    let defaultID = AudioOutput.defaultOutputID
    for d in pairedDevices() where d.isConnected {
        if let out = AudioOutput.device(forBluetoothAddress: d.address, name: d.name) {
            print("\(d.name): output \"\(out.name)\" uid \(out.uid)\(out.id == defaultID ? "  ← Mac sound output" : "")")
        } else {
            print("\(d.name): no CoreAudio output device")
        }
    }

case "eqbands":
    let list = argument(2, "comma-separated band values")
    let values = list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !values.isEmpty else { fail("bands look like 0,1,-2,…") }
    applySetting { try stageEqualizerBands($0, values) }

case "control":
    guard let location = UInt32(argument(2, "key location (1 = left, 2 = right)")),
          let action = UInt32(argument(3, "action id (listed by `status`)")) else { fail("expected numbers") }
    applySetting { try stageControl($0, location: location, action: action) }

case "dsee":
    let on = parseOnOff(argument(2, "on|off"))
    applySetting { try check(mdrHeadphonesSetDSEE($0, on), "SetDSEE") }

case "stc":
    let on = parseOnOff(argument(2, "on|off"))
    applySetting { dev in
        guard var stc = readSpeakToChat(dev, PROPERTY_DESIRED) else { throw XMError("no speak-to-chat") }
        stc.enabled = on
        try check(mdrHeadphonesSetSpeakToChat(dev, &stc), "SetSpeakToChat")
    }

case "autooff":
    guard let minutes = UInt32(argument(2, "minutes (0 = never)")) else { fail("minutes must be a number") }
    applySetting { dev in
        guard var p = readPower(dev, PROPERTY_DESIRED)?.raw else { throw XMError("no power settings") }
        p.auto_power_off_minutes = minutes
        try check(mdrHeadphonesSetPower(dev, &p), "SetPower")
    }

default:
    print(usage)
    exit(2)
}
