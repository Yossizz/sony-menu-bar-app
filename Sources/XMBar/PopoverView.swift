import SwiftUI
import XMKit

struct PopoverView: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if c.phase == .ready {
                BatteryRow(batteries: c.batteries)
                NoiseControlSection()
                Divider()
                HStack {
                    devicePicker
                    Spacer()
                    Button("Disconnect") { c.disconnect() }
                }
            } else {
                connectSection
            }
            Divider()
            HStack {
                Text("Unofficial · not affiliated with Sony")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { c.refreshDevices() }
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
            if c.phase == .connecting || c.phase == .initializing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusLine: String {
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
                Text("Take \(d.name) out of the case, or connect it in Bluetooth settings. "
                    + "The app connects automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                devicePicker
                Spacer()
                Button("Connect") { c.connectIfPossible(retries: 0) }
                    .disabled(c.selectedDevice?.isConnected != true
                        || c.phase == .connecting || c.phase == .initializing)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var devicePicker: some View {
        Picker("", selection: $c.selectedAddress) {
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

// MARK: Battery

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

// MARK: Noise control

struct NoiseControlSection: View {
    @EnvironmentObject var c: HeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise control").font(.subheadline.weight(.semibold))
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
