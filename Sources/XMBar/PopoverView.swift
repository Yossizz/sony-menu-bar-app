import SwiftUI
import XMKit

// Panel shown from the menu bar item, styled after macOS Control Center:
// a header with a device menu, a tab switcher, and content grouped into cards.
//
// Note: the macOS SDK implements SwiftUI's @State as a compiler macro whose plugin isn't
// shipped with the Command Line Tools, so view-local state lives on ObservableObjects
// (`HeadphonesController`, `Preferences`) or @AppStorage instead.

struct PopoverView: View {
    @EnvironmentObject var c: HeadphonesController
    @AppStorage("tab") private var tab: Tab = .controls

    enum Tab: String, CaseIterable { case controls = "Controls", sound = "Sound", settings = "Settings" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header()
            if c.phase == .ready {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch tab {
                case .controls: ControlsTab()
                case .sound: SoundTab()
                case .settings: SettingsTab()
                }
            } else {
                ConnectCard()
                if tab == .settings { Card { AppSettingsSection(prefs: c.prefs) } }
            }
            if let notice = c.notice {
                NoticeBanner(text: notice) { c.notice = nil }
            }
            Footer(showSettingsButton: c.phase != .ready, tab: $tab)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            c.refreshDevices()
            c.refreshSoundOutput()
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
    }
}

/// A row with a label on the left and a compact menu picker on the right.
struct LabeledPicker<Value: Hashable>: View {
    let title: String
    let selection: Binding<Value>
    let options: [(Value, String)]

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .font(.callout)
    }
}

/// A switch row, the Control Center way: label left, small switch right.
struct SwitchRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) { Text(title).font(.callout) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Header and footer

struct Header: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(c.phase == .ready ? Color.accentColor : Color.primary.opacity(0.1))
                ProductGlyph(kind: ProductKind(device: c.selectedDevice))
                    .foregroundStyle(c.phase == .ready ? Color.white : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(c.modelName ?? c.selectedDevice?.name ?? "No headphones")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if c.phase == .ready && c.isSoundOutput {
                        Image(systemName: "speaker.wave.2.fill").font(.caption2)
                    }
                    Text(statusLine).font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if c.phase == .connecting || c.phase == .initializing || c.bluetoothConnecting {
                ProgressView().controlSize(.small)
            }
            DeviceMenu()
        }
    }

    private var statusLine: String {
        if c.bluetoothConnecting { return "Connecting Bluetooth…" }
        switch c.phase {
        case .ready:
            let fw = c.firmware.map { " · FW \($0)" } ?? ""
            return (c.isSoundOutput ? "Mac sound output" : "Connected") + fw
        case .connecting: return "Connecting…"
        case .initializing: return "Reading settings…"
        case .failed: return "Not connected"
        case .idle:
            guard let d = c.selectedDevice else { return "Choose headphones" }
            return d.isConnected ? "Not connected" : "Not connected to this Mac"
        }
    }
}

/// The "…" menu: switch headphones, route sound, connect/disconnect, quit.
struct DeviceMenu: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        Menu {
            Section("Headphones") {
                ForEach(c.devices) { d in
                    Button { c.switchTo(d.address) } label: {
                        if d.address == c.selectedAddress {
                            Label(d.name, systemImage: "checkmark")
                        } else {
                            Text(d.isConnected ? d.name : "\(d.name) — not connected")
                        }
                    }
                }
            }
            Divider()
            if c.phase == .ready {
                Button("Use for Mac Sound") { c.useAsSoundOutput() }
                    .disabled(c.isSoundOutput)
                Button("Disconnect") { c.disconnect() }
            } else if let d = c.selectedDevice {
                Button("Connect") {
                    if d.isConnected { c.connectIfPossible(retries: 0) } else { c.switchTo(d.address) }
                }
            }
            Divider()
            Button("Quit XMBar") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Headphones and connection")
    }
}

struct Footer: View {
    let showSettingsButton: Bool
    @Binding var tab: PopoverView.Tab

    var body: some View {
        HStack(spacing: 8) {
            if showSettingsButton {
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
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Not connected

struct ConnectCard: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        Card {
            if case .failed(let message) = c.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let d = c.selectedDevice, !d.isConnected {
                Text("Take \(d.name) out of the case, or press Connect to bring it to this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if c.selectedDevice == nil {
                Text("Choose your headphones. They need to be paired in System Settings → Bluetooth.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("", selection: Binding(get: { c.selectedAddress },
                                              set: { if let a = $0 { c.switchTo(a) } })) {
                    if c.selectedAddress == nil { Text("Choose…").tag(String?.none) }
                    ForEach(c.devices) { d in
                        Text(d.isConnected ? d.name : "\(d.name) (not connected)").tag(Optional(d.address))
                    }
                }
                .labelsHidden()
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
}

// MARK: - Controls tab

struct ControlsTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(spacing: 10) {
            Card { BatteryTiles(batteries: c.batteries, kind: ProductKind(device: c.selectedDevice)) }
            Card { NoiseControlSection() }
            if let l = c.listening, l.available.count > 1 {
                Card {
                    LabeledPicker(title: "Listening mode",
                                  selection: Binding(get: { l.mode }, set: { c.setListeningMode($0) }),
                                  options: l.available.map { ($0, describe(listeningMode: $0)) })
                }
            }
            if !c.isSoundOutput {
                Card {
                    HStack {
                        Label("Not the Mac's sound output", systemImage: "speaker.slash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use") { c.useAsSoundOutput() }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct BatteryTiles: View {
    let batteries: [HeadphonesController.Battery]
    let kind: ProductKind

    var body: some View {
        if batteries.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading battery…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 14) {
                ForEach(batteries) { BatteryTile(battery: $0, kind: kind) }
            }
        }
    }
}

struct BatteryTile: View {
    let battery: HeadphonesController.Battery
    let kind: ProductKind

    private var title: String {
        switch battery.label {
        case "L": return "Left"
        case "R": return "Right"
        case "": return "Battery"
        default: return battery.label
        }
    }

    private var color: Color {
        if battery.charging { return .green }
        switch battery.percent {
        case ...10: return .red
        case ...20: return .orange
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                BatteryPartGlyph(label: battery.label, kind: kind)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(title).font(.caption).foregroundStyle(.secondary)
                if battery.charging {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
                }
            }
            Text("\(battery.percent)%")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(battery.percent) / 100))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoiseControlSection: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Noise Control")
            HStack(spacing: 0) {
                ForEach(c.availableModes, id: \.self) { mode in
                    ModeButton(title: title(mode), symbol: symbol(mode), selected: c.noise.mode == mode) {
                        c.setMode(mode)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if c.noise.mode == .ambient {
                Divider()
                if c.supportsAdaptiveAmbient {
                    SwitchRow(title: "Adjust level automatically",
                              isOn: Binding(get: { c.noise.adaptive }, set: { c.setAdaptiveAmbient($0) }))
                }
                HStack(spacing: 8) {
                    Image(systemName: "ear").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(c.noise.ambientLevel) },
                                          set: { c.setAmbientLevel(Int($0.rounded())) }),
                           in: Double(c.ambientRange.lowerBound)...Double(c.ambientRange.upperBound),
                           step: 1)
                        .controlSize(.small)
                    Text("\(c.noise.ambientLevel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .disabled(c.supportsAdaptiveAmbient && c.noise.adaptive)
                .opacity(c.supportsAdaptiveAmbient && c.noise.adaptive ? 0.4 : 1)
                SwitchRow(title: "Focus on voice",
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

    private func symbol(_ mode: HeadphonesController.NoiseMode) -> String {
        switch mode {
        case .off: return "person.fill"
        case .cancelling: return "person.wave.2.fill"
        case .ambient: return "ear.fill"
        case .windReduction: return "wind"
        }
    }
}

/// Round icon button with a caption, like the AirPods listening-mode buttons in Control Center.
struct ModeButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1))
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .frame(width: 44, height: 44)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sound tab

struct SoundTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(spacing: 10) {
            if let eq = c.equalizer {
                Card {
                    HStack {
                        SectionTitle("Equalizer")
                        Spacer()
                        if !eq.presets.isEmpty {
                            Picker("", selection: Binding(get: { eq.preset }, set: { c.setEqualizerPreset($0) })) {
                                ForEach(eq.presets, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .controlSize(.small)
                        }
                    }
                    if !eq.bands.isEmpty {
                        BandEditor(eq: eq)
                        HStack {
                            Text("Editing a band switches to Custom.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Flat") { c.resetEqualizerBands() }
                                .controlSize(.small)
                        }
                    }
                    if let cb = eq.clearBass, let r = eq.clearBassRange {
                        ValueSlider(title: "Bass", value: cb, range: r, signed: true) { c.setClearBass($0) }
                    }
                }
                if eq.dseeAvailable {
                    Card {
                        SwitchRow(title: "DSEE upscaling",
                                  isOn: Binding(get: { eq.dseeEnabled }, set: { c.setDSEE($0) }))
                    }
                }
            } else {
                Card {
                    Text("These headphones don't offer equalizer settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One slider per band, labeled by centre frequency.
struct BandEditor: View {
    @EnvironmentObject var c: HeadphonesController
    let eq: EqualizerInfo

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(eq.bands.enumerated()), id: \.offset) { i, value in
                let hz = eq.bandFrequencies[safe: i] ?? 0
                ValueSlider(title: hz > 0 ? formatFrequency(hz) : "\(i + 1)", value: value,
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
                .frame(width: 32, alignment: .trailing)
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .controlSize(.mini)
            Text(signed && value > 0 ? "+\(value)" : "\(value)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(width: 22, alignment: .trailing)
        }
    }
}

// MARK: - Settings tab

struct SettingsTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(spacing: 10) {
            if let stc = c.speakToChat {
                Card {
                    SwitchRow(title: "Speak-to-Chat",
                              isOn: Binding(get: { stc.enabled }, set: { c.setSpeakToChat(enabled: $0) }))
                    if stc.enabled {
                        LabeledPicker(title: "Voice detection",
                                      selection: Binding(get: { stc.sensitivity },
                                                         set: { c.setSpeakToChat(sensitivity: $0) }),
                                      options: [MDR_SPEECH_SENSITIVITY_AUTO, MDR_SPEECH_SENSITIVITY_LOW,
                                                MDR_SPEECH_SENSITIVITY_HIGH].map {
                                          let v = MDRSpeechSensitivity($0)
                                          return (v, describe(speechSensitivity: v).capitalized)
                                      })
                        LabeledPicker(title: "End after",
                                      selection: Binding(get: { stc.timeout }, set: { c.setSpeakToChat(timeout: $0) }),
                                      options: [MDR_SPEAK_TIMEOUT_SHORT, MDR_SPEAK_TIMEOUT_MEDIUM,
                                                MDR_SPEAK_TIMEOUT_LONG, MDR_SPEAK_TIMEOUT_MANUAL].map {
                                          let v = MDRSpeakTimeout($0)
                                          return (v, describe(speakTimeout: v).capitalized)
                                      })
                    }
                }
            }

            if !c.controls.isEmpty {
                Card {
                    SectionTitle("Touch Controls")
                    ForEach(c.controls) { control in
                        LabeledPicker(title: describe(keyLocation: control.location, type: control.keyType)
                                          .replacingOccurrences(of: " touch", with: ""),
                                      selection: Binding(get: { control.action },
                                                         set: { c.setControl(control.location, to: $0) }),
                                      options: control.options.map { ($0, describe(assignableAction: $0)) })
                    }
                }
            }

            if let p = c.power, hasPowerRows(p) {
                Card {
                    SectionTitle("Power")
                    if p.options.count > 1 {
                        LabeledPicker(title: "Turn off when idle",
                                      selection: Binding(get: { p.minutes }, set: { c.setAutoPowerOff(minutes: $0) }),
                                      options: p.options.map { ($0, describe(autoOffMinutes: $0)) })
                    }
                    if p.raw.wearing_power != MDRWearingPowerMode(MDR_WEARING_POWER_UNAVAILABLE) {
                        SwitchRow(title: "Turn off when removed",
                                  isOn: Binding(get: {
                                      p.raw.wearing_power == MDRWearingPowerMode(MDR_WEARING_POWER_WHEN_REMOVED)
                                  }, set: { c.setPowerOffWhenRemoved($0) }))
                    }
                    if p.autoPauseAvailable {
                        SwitchRow(title: "Pause when removed",
                                  isOn: Binding(get: { p.raw.auto_pause == MDR_YES }, set: { c.setAutoPause($0) }))
                    }
                }
            }

            Card { AppSettingsSection(prefs: c.prefs) }
        }
    }

    private func hasPowerRows(_ p: PowerInfo) -> Bool {
        p.options.count > 1 || p.autoPauseAvailable
            || p.raw.wearing_power != MDRWearingPowerMode(MDR_WEARING_POWER_UNAVAILABLE)
    }
}

/// Mac-side preferences: available even when no headphones are connected.
struct AppSettingsSection: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("XMBar")
            SwitchRow(title: "Launch at login",
                      isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
            if let loginMessage = prefs.loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.secondary)
            }
            SwitchRow(title: "Use for Mac sound when connected", isOn: $prefs.autoSwitchOutput)
            HStack {
                SwitchRow(title: "Low battery alert", isOn: $prefs.lowBatteryAlerts)
                Picker("", selection: $prefs.lowBatteryThreshold) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(!prefs.lowBatteryAlerts)
            }
            SwitchRow(title: "Connect & disconnect alerts", isOn: $prefs.connectionAlerts)
        }
        .onAppear { prefs.refreshLaunchAtLogin() }
    }
}
