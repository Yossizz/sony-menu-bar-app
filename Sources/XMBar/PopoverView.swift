import IOBluetooth
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

    enum Tab: String, CaseIterable {
        case controls = "Controls", sound = "Sound", devices = "Devices", settings = "Settings"
    }

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
                case .devices: DevicesTab()
                case .settings: SettingsTab()
                }
            } else {
                ConnectCard()
                if tab == .settings { Card { AppSettingsSection(prefs: c.prefs) } }
            }
            if let alert = c.pendingAlert {
                AlertBanner(text: alert, answer: c.answerAlert)
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
            Text("XMBar by Yossizz · not affiliated with Sony")
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
            Card { BatteryTiles(batteries: c.batteries, kind: ProductKind(device: c.selectedDevice), wearing: c.wearing) }
            if let now = c.nowPlaying { Card { NowPlayingCard(now: now) } }
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
    var wearing: Wearing?

    var body: some View {
        if batteries.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading battery…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 14) {
                ForEach(batteries) { BatteryTile(battery: $0, kind: kind, inEar: inEar($0.label)) }
            }
        }
    }
}

extension BatteryTiles {
    /// nil when unknown or not an earbud; otherwise whether that bud is in the ear.
    func inEar(_ label: String) -> Bool? {
        guard let wearing else { return nil }
        switch label {
        case "L": return !(wearing == .leftOut || wearing == .bothOut)
        case "R": return !(wearing == .rightOut || wearing == .bothOut)
        case "": return wearing == .worn
        default: return nil
        }
    }
}

struct BatteryTile: View {
    let battery: HeadphonesController.Battery
    let kind: ProductKind
    var inEar: Bool?

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
                if let inEar {
                    Circle()
                        .fill(inEar ? Color.green : Color.clear)
                        .overlay(Circle().stroke(inEar ? Color.green : Color.secondary, lineWidth: 1))
                        .frame(width: 6, height: 6)
                        .help(inEar ? "In ear" : "Out of ear")
                }
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
            SwitchRow(title: "Pause when an earbud is removed", isOn: $prefs.pauseWhenRemoved)
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

// MARK: - Alerts from the headphones

struct AlertBanner: View {
    let text: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "questionmark.circle.fill")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { answer(false) }
                Button("Continue") { answer(true) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @EnvironmentObject var c: HeadphonesController
    let now: NowPlaying

    private var source: String? { c.peers.first { $0.isPlaybackSource }?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.title ?? (now.isPlaying ? "Playing" : "Not playing"))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    let detail = [now.artist, now.album].compactMap { $0 }.joined(separator: " · ")
                    Text(detail.isEmpty ? (source.map { "from \($0)" } ?? " ") : detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 14) {
                    transport("backward.fill", MDR_PLAYBACK_PREVIOUS)
                    transport(now.isPlaying ? "pause.fill" : "play.fill",
                              now.isPlaying ? MDR_PLAYBACK_PAUSE : MDR_PLAYBACK_PLAY, size: 20)
                    transport("forward.fill", MDR_PLAYBACK_NEXT)
                }
            }
            if let volume = now.volume, let range = now.volumeRange {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(volume) }, set: { c.setVolume(Int($0.rounded())) }),
                           in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                        .controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func transport(_ symbol: String, _ action: UInt32, size: CGFloat = 15) -> some View {
        Button { c.playback(MDRPlaybackAction(action)) } label: {
            Image(systemName: symbol).font(.system(size: size))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Devices tab (multipoint)

struct DevicesTab: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(spacing: 10) {
            if c.peers.isEmpty {
                Card {
                    Text("These headphones don't report their connected devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Card {
                    SectionTitle("Connected Devices")
                    ForEach(c.peers) { PeerRow(peer: $0) }
                    Text("The headphones can be connected to two devices at once. "
                        + "Pick which one they play from.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let auto = c.autoSourceSwitch {
                Card {
                    SwitchRow(title: "Switch to the device that starts playing",
                              isOn: Binding(get: { auto }, set: { c.setAutoSourceSwitch($0) }))
                    Text(auto ? "Audio follows whichever device plays." : "Audio stays on the selected device.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct PeerRow: View {
    @EnvironmentObject var c: HeadphonesController
    let peer: HeadsetPeer

    private var isThisMac: Bool { peer.address.uppercased() == thisMacAddress }

    private var symbol: String {
        let n = peer.name.lowercased()
        if isThisMac || n.contains("mac") { return "laptopcomputer" }
        if n.contains("ipad") || n.contains("tab") { return "ipad" }
        if n.contains("iphone") || n.contains("phone") || n.contains("pixel") || n.contains("galaxy") { return "iphone" }
        if n.contains("tv") { return "tv" }
        return "display"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(peer.connected ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(isThisMac ? "\(peer.name) (this Mac)" : peer.name).font(.callout).lineLimit(1)
                Text(peer.isPlaybackSource ? "Playing" : (peer.connected ? "Connected" : "Not connected"))
                    .font(.caption)
                    .foregroundStyle(peer.isPlaybackSource ? Color.accentColor : Color.secondary)
            }
            Spacer()
            if peer.connected && !peer.isPlaybackSource {
                Button("Play") { c.peerCommand(MDRPairedDeviceCommand(MDR_PAIRED_DEVICE_SELECT_PLAYBACK), peer) }
                    .controlSize(.small)
                    .help("Play audio from this device")
            }
            Menu {
                if peer.connected {
                    // Disconnecting this Mac would cut the app's own control channel.
                    Button("Disconnect") { c.peerCommand(MDRPairedDeviceCommand(MDR_PAIRED_DEVICE_DISCONNECT), peer) }
                        .disabled(isThisMac)
                } else {
                    Button("Connect") { c.peerCommand(MDRPairedDeviceCommand(MDR_PAIRED_DEVICE_CONNECT), peer) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// This Mac's Bluetooth address, "AA:BB:…" upper case.
let thisMacAddress: String = {
    guard let raw = IOBluetoothHostController.default()?.addressAsString() else { return "" }
    return normalizeAddress(raw)
}()
