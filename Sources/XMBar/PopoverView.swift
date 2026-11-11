import SwiftUI
import XMKit

struct PopoverView: View {
    @EnvironmentObject var c: HeadphonesController
    @AppStorage("tab") private var tab: Tab = .controls

    enum Tab: String, CaseIterable { case controls = "Controls", sound = "Sound", settings = "Settings" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if c.phase == .ready {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                switch tab {
                case .controls: ControlsTab()
                case .sound: SoundTab()
                case .settings: SettingsTab()
                }
            } else {
                Divider()
                connectSection
                if tab == .settings { Divider(); AppSettingsSection(prefs: c.prefs) }
            }
            if let notice = c.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            c.refreshDevices()
            c.refreshSoundOutput()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: c.selectedDevice?.isEarbuds == true ? "earbuds" : "headphones")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.modelName ?? c.selectedDevice?.name ?? "No headphones selected")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if c.phase == .connecting || c.phase == .initializing || c.bluetoothConnecting {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusLine: String {
        if c.bluetoothConnecting { return "Connecting Bluetooth…" }
        switch c.phase {
        case .ready: return c.firmware.map { "Connected · firmware \($0)" } ?? "Connected"
        case .connecting: return "Connecting…"
        case .initializing: return "Reading settings…"
        case .failed: return "Not connected"
        case .idle:
            guard let d = c.selectedDevice else { return "Pick your headphones below" }
            return d.isConnected ? "Not connected" : "Not connected to this Mac"
        }
    }

    // MARK: Not ready

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = c.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if c.phase == .idle, let d = c.selectedDevice, !d.isConnected {
                Text("Take \(d.name) out of the case, or press Connect to bring it to this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                DevicePicker()
                Spacer()
                Button("Connect") {
                    guard let d = c.selectedDevice else { return }
                    if d.isConnected { c.connectIfPossible(retries: 0) } else { c.switchTo(d.address) }
                }
                .disabled(c.selectedDevice == nil || c.phase == .connecting || c.phase == .initializing
                    || c.bluetoothConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footer: some View {
        HStack {
            if c.phase != .ready {
                Button { tab = tab == .settings ? .controls : .settings } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("App settings")
            }
            Text("Unofficial · not affiliated with Sony")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Shared pieces

/// Picks which paired headphones to control. Choosing one that isn't connected connects it.
struct DevicePicker: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        Picker("", selection: Binding(get: { c.selectedAddress }, set: { if let a = $0 { c.switchTo(a) } })) {
            if c.selectedAddress == nil { Text("Choose…").tag(String?.none) }
            ForEach(c.devices) { d in
                Text(d.isConnected ? d.name : "\(d.name) (not connected)")
                    .tag(Optional(d.address))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.subheadline.weight(.semibold)) }
}

/// A Picker row with the label on the left, sized for the narrow panel.
struct LabeledPicker<Value: Hashable>: View {
    let title: String
    let selection: Binding<Value>
    let options: [(Value, String)]

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

// MARK: - Controls tab

struct ControlsTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatteryRow(batteries: c.batteries)
            NoiseControlSection()
            if let l = c.listening, l.available.count > 1 {
                LabeledPicker(title: "Listening mode",
                              selection: Binding(get: { l.mode }, set: { c.setListeningMode($0) }),
                              options: l.available.map { ($0, describe(listeningMode: $0)) })
            }
            Divider()
            HStack {
                DevicePicker()
                Spacer()
                if c.isSoundOutput {
                    Label("Mac sound", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("These headphones are the Mac's sound output")
                } else {
                    Button("Use for Mac sound") { c.useAsSoundOutput() }
                }
                Button("Disconnect") { c.disconnect() }
            }
        }
    }
}

struct BatteryRow: View {
    let batteries: [HeadphonesController.Battery]

    var body: some View {
        HStack(spacing: 16) {
            if batteries.isEmpty {
                Label("Battery: reading…", systemImage: "battery.0")
                    .foregroundStyle(.secondary)
            }
            ForEach(batteries) { b in
                HStack(spacing: 4) {
                    Image(systemName: symbol(for: b))
                        .foregroundStyle(b.percent <= 15 && !b.charging ? .red : .primary)
                    Text(b.label.isEmpty ? "\(b.percent)%" : "\(b.label) \(b.percent)%")
                        .monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private func symbol(for b: HeadphonesController.Battery) -> String {
        if b.charging { return "battery.100.bolt" }
        switch b.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct NoiseControlSection: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Noise control")
            Picker("", selection: Binding(get: { c.noise.mode }, set: { c.setMode($0) })) {
                ForEach(c.availableModes, id: \.self) { mode in
                    Text(title(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if c.noise.mode == .ambient {
                if c.supportsAdaptiveAmbient {
                    Toggle("Adjust ambient level automatically",
                           isOn: Binding(get: { c.noise.adaptive }, set: { c.setAdaptiveAmbient($0) }))
                }
                HStack {
                    Text("Level").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(c.noise.ambientLevel) },
                                          set: { c.setAmbientLevel(Int($0.rounded())) }),
                           in: Double(c.ambientRange.lowerBound)...Double(c.ambientRange.upperBound),
                           step: 1)
                    Text("\(c.noise.ambientLevel)")
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }
                .disabled(c.supportsAdaptiveAmbient && c.noise.adaptive)
                Toggle("Focus on voice",
                       isOn: Binding(get: { c.noise.focusOnVoice }, set: { c.setFocusOnVoice($0) }))
            }
        }
    }

    private func title(_ mode: HeadphonesController.NoiseMode) -> String {
        switch mode {
        case .off: return "Off"
        case .cancelling: return "Noise Cancelling"
        case .ambient: return "Ambient"
        case .windReduction: return "Wind"
        }
    }
}

// MARK: - Sound tab

struct SoundTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eq = c.equalizer {
                HStack {
                    SectionTitle("Equalizer")
                    Spacer()
                    if !eq.presets.isEmpty {
                        Picker("", selection: Binding(get: { eq.preset }, set: { c.setEqualizerPreset($0) })) {
                            ForEach(eq.presets, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if !eq.bands.isEmpty {
                    BandEditor(eq: eq)
                    HStack {
                        Text("Editing a band switches to the Custom preset.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Flat") { c.resetEqualizerBands() }
                            .controlSize(.small)
                    }
                }
                if let cb = eq.clearBass, let r = eq.clearBassRange {
                    ValueSlider(title: "Clear Bass", value: cb, range: r) { c.setClearBass($0) }
                }
                if eq.dseeAvailable {
                    Divider()
                    Toggle("DSEE upscaling", isOn: Binding(get: { eq.dseeEnabled }, set: { c.setDSEE($0) }))
                }
            } else {
                Text("These headphones don't offer equalizer settings.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One horizontal slider per band, labeled by centre frequency.
struct BandEditor: View {
    @EnvironmentObject var c: HeadphonesController
    let eq: EqualizerInfo

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(eq.bands.enumerated()), id: \.offset) { i, value in
                let hz = eq.bandFrequencies[safe: i] ?? 0
                ValueSlider(title: hz > 0 ? formatFrequency(hz) : "Band \(i + 1)", value: value,
                            range: eq.bandRange, signed: true) { c.setEqualizerBand(i, to: $0) }
            }
        }
    }
}

struct ValueSlider: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    var signed = false
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .controlSize(.small)
            Text(signed && value > 0 ? "+\(value)" : "\(value)")
                .font(.caption.monospacedDigit())
                .frame(width: 24, alignment: .trailing)
        }
    }
}

// MARK: - Settings tab

struct SettingsTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stc = c.speakToChat {
                Toggle(isOn: Binding(get: { stc.enabled }, set: { c.setSpeakToChat(enabled: $0) })) {
                    SectionTitle("Speak-to-Chat")
                }
                if stc.enabled {
                    LabeledPicker(title: "Voice detection",
                                  selection: Binding(get: { stc.sensitivity }, set: { c.setSpeakToChat(sensitivity: $0) }),
                                  options: [MDR_SPEECH_SENSITIVITY_AUTO, MDR_SPEECH_SENSITIVITY_LOW,
                                            MDR_SPEECH_SENSITIVITY_HIGH].map {
                                      (MDRSpeechSensitivity($0), describe(speechSensitivity: MDRSpeechSensitivity($0)).capitalized)
                                  })
                    LabeledPicker(title: "End after",
                                  selection: Binding(get: { stc.timeout }, set: { c.setSpeakToChat(timeout: $0) }),
                                  options: [MDR_SPEAK_TIMEOUT_SHORT, MDR_SPEAK_TIMEOUT_MEDIUM, MDR_SPEAK_TIMEOUT_LONG,
                                            MDR_SPEAK_TIMEOUT_MANUAL].map {
                                      (MDRSpeakTimeout($0), describe(speakTimeout: MDRSpeakTimeout($0)).capitalized)
                                  })
                }
                Divider()
            }

            if !c.controls.isEmpty {
                SectionTitle("Touch controls")
                ForEach(c.controls) { control in
                    LabeledPicker(title: describe(keyLocation: control.location, type: control.keyType),
                                  selection: Binding(get: { control.action },
                                                     set: { c.setControl(control.location, to: $0) }),
                                  options: control.options.map { ($0, describe(assignableAction: $0)) })
                }
                Divider()
            }

            if let p = c.power {
                SectionTitle("Power")
                if p.options.count > 1 {
                    LabeledPicker(title: "Turn off when idle",
                                  selection: Binding(get: { p.minutes }, set: { c.setAutoPowerOff(minutes: $0) }),
                                  options: p.options.map { ($0, describe(autoOffMinutes: $0)) })
                }
                if p.raw.wearing_power != MDRWearingPowerMode(MDR_WEARING_POWER_UNAVAILABLE) {
                    Toggle("Turn off when removed from ears",
                           isOn: Binding(get: { p.raw.wearing_power == MDRWearingPowerMode(MDR_WEARING_POWER_WHEN_REMOVED) },
                                         set: { c.setPowerOffWhenRemoved($0) }))
                }
                if p.autoPauseAvailable {
                    Toggle("Pause when removed",
                           isOn: Binding(get: { p.raw.auto_pause == MDR_YES }, set: { c.setAutoPause($0) }))
                }
                Divider()
            }

            AppSettingsSection(prefs: c.prefs)
        }
    }
}

/// Mac-side preferences: available even when no headphones are connected.
struct AppSettingsSection: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("App")
            Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
            if let loginMessage = prefs.loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Switch Mac sound to the headphones when they connect", isOn: $prefs.autoSwitchOutput)
            HStack {
                Toggle("Low battery alert at", isOn: $prefs.lowBatteryAlerts)
                Picker("", selection: $prefs.lowBatteryThreshold) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!prefs.lowBatteryAlerts)
            }
            Toggle("Notify on connect and disconnect", isOn: $prefs.connectionAlerts)
        }
        .onAppear { prefs.refreshLaunchAtLogin() }
    }
}
