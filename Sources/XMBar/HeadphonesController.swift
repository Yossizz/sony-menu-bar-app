import AppKit
import Combine
import IOBluetooth
import XMKit

/// Non-blocking owner of one libmdr connection, driven by a main-run-loop timer.
///
/// Everything here runs on the main thread: libmdr's macOS backend does its IOBluetooth work
/// on the main queue, SwiftUI reads the published state there, and IOBluetooth delivers
/// connect/disconnect notifications there.
final class HeadphonesController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle               // nothing selected, or selected device isn't connected
        case connecting         // opening RFCOMM (trying V2, then V1)
        case initializing       // channel open, libmdr querying the device
        case ready
        case failed(String)
    }

    enum NoiseMode: Hashable { case off, cancelling, ambient, windReduction }

    struct NoiseState: Equatable {
        var mode: NoiseMode = .off
        var ambientLevel = 0
        var focusOnVoice = false
        var adaptive = false
    }

    struct Battery: Equatable, Identifiable {
        let label: String // "", "L", "R", "Case"
        let percent: Int
        let charging: Bool
        var id: String { label }
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { NSLog("XMBar phase: %@", String(describing: phase)) } }
    }
    @Published private(set) var devices: [PairedDevice] = []
    @Published var selectedAddress: String? {
        didSet {
            guard selectedAddress != oldValue else { return }
            UserDefaults.standard.set(selectedAddress, forKey: Self.selectedKey)
            disconnect()
            connectIfPossible()
        }
    }
    @Published private(set) var modelName: String?
    @Published private(set) var firmware: String?
    @Published private(set) var batteries: [Battery] = [] {
        didSet {
            if batteries != oldValue, !batteries.isEmpty {
                NSLog("XMBar battery: %@", batteries.map { "\($0.label) \($0.percent)%" }.joined(separator: ", "))
            }
        }
    }
    @Published private(set) var noise = NoiseState() {
        didSet { if noise != oldValue { NSLog("XMBar noise: %@", String(describing: noise)) } }
    }
    @Published private(set) var availableModes: [NoiseMode] = []
    @Published private(set) var ambientRange: ClosedRange<Int> = 0...20
    @Published private(set) var supportsAdaptiveAmbient = false

    var selectedDevice: PairedDevice? { devices.first { $0.address == selectedAddress } }

    /// Lowest earbud/headphone level, for the menu bar title (the case doesn't count).
    var headlineBattery: Int? {
        batteries.filter { $0.label != "Case" }.map(\.percent).min()
    }

    // MARK: libmdr handles

    private static let selectedKey = "selectedAddress"
    private let backend: OpaquePointer = mdrConnectionMacOSCreate() // MDRConnectionMacOS*
    private lazy var conn: UnsafeMutablePointer<MDRConnection> = mdrConnectionMacOSGet(backend)
    private var device: OpaquePointer? // MDRHeadphones*

    private var timer: Timer?
    private var services: [String] = []
    private var serviceIndex = 0
    private var connectDeadline = Date.distantPast
    private var needSync = false
    private var lastSync = Date.distantPast
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var autoRetriesLeft = 0

    private static let connectTimeout: TimeInterval = 10
    private static let batteryRefresh: TimeInterval = 60

    override init() {
        super.init()
        selectedAddress = UserDefaults.standard.string(forKey: Self.selectedKey)
        refreshDevices()
        if selectedAddress == nil {
            selectedAddress = devices.first { $0.looksLikeSony && $0.isConnected }?.address
                ?? devices.first { $0.looksLikeSony }?.address
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(bluetoothDeviceConnected(_:device:)))
        connectIfPossible()
    }

    // MARK: Device list & connection

    func refreshDevices() {
        devices = pairedDevices()
    }

    /// Connects when the selected device has an active Bluetooth link and we're not already busy.
    func connectIfPossible(retries: Int = 2) {
        refreshDevices()
        guard let address = selectedAddress, selectedDevice?.isConnected == true else {
            if case .failed = phase { return }
            phase = .idle
            return
        }
        switch phase {
        case .connecting, .initializing, .ready: return
        case .idle, .failed: break
        }
        autoRetriesLeft = retries
        startConnect(address: address)
    }

    func disconnect() {
        teardown(next: .idle)
    }

    private func startConnect(address: String) {
        services = defaultServiceOrder
        serviceIndex = 0
        phase = .connecting
        startTimer()
        tryNextService(address: address, previousError: nil)
    }

    private func tryNextService(address: String, previousError: String?) {
        while serviceIndex < services.count {
            let r = mdrConnectionConnect(conn, address, services[serviceIndex])
            if r == OK || r == IN_PROGRESS {
                connectDeadline = Date(timeIntervalSinceNow: Self.connectTimeout)
                return
            }
            mdrConnectionDisconnect(conn)
            serviceIndex += 1
        }
        let reason = previousError ?? "the headphones did not open a control channel"
        if autoRetriesLeft > 0 {
            // Right after the audio link comes up the control service often isn't listening yet.
            autoRetriesLeft -= 1
            teardown(next: .connecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.phase == .connecting, let a = self.selectedAddress else { return }
                self.startConnect(address: a)
            }
        } else {
            teardown(next: .failed("Couldn't connect: \(reason)"))
        }
    }

    private func channelOpened() {
        let version = protocolVersion(forService: services[serviceIndex])
        var dev: OpaquePointer?
        guard mdrHeadphonesCreate(XM_ABI_VERSION, conn, version, &dev) == OK, let dev else {
            teardown(next: .failed("libmdr refused this device"))
            return
        }
        device = dev
        guard mdrHeadphonesRequestInit(dev, XM_INIT_DEFAULT) == OK else {
            teardown(next: .failed("Couldn't start talking to the headphones"))
            return
        }
        phase = .initializing
        if let address = selectedAddress, let bt = IOBluetoothDevice(addressString: address) {
            disconnectNotification = bt.register(
                forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        }
    }

    private func teardown(next: Phase) {
        timer?.invalidate()
        timer = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        if let device { mdrHeadphonesDestroy(device) }
        device = nil
        mdrConnectionDisconnect(conn)
        needSync = false
        batteries = []
        modelName = nil
        firmware = nil
        availableModes = []
        phase = next
    }

    // MARK: Event loop

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // keep polling while the popover is tracking
        timer = t
    }

    private func tick() {
        switch phase {
        case .connecting:
            guard serviceIndex < services.count, let address = selectedAddress else { return }
            let r = mdrConnectionPoll(conn, 0)
            if r == OK {
                channelOpened()
            } else if (r != IN_PROGRESS && r != TIMEOUT) || Date() >= connectDeadline {
                let detail = String(cString: mdrConnectionGetLastError(conn))
                mdrConnectionDisconnect(conn)
                serviceIndex += 1
                tryNextService(address: address, previousError: detail.isEmpty ? resultString(r) : detail)
            }
        case .initializing, .ready:
            pollDevice()
        case .idle, .failed:
            break
        }
    }

    private func pollDevice() {
        guard let device else { return }
        for _ in 0..<128 { // bounded so a chatty device can't starve the UI
            var event = MDREvent(MDR_EVENT_NONE)
            let r = mdrHeadphonesPoll(device, &event)
            guard r == OK else {
                let detail = mdrText(device, MDRText(MDR_TEXT_LAST_ERROR)) ?? resultString(r)
                let stillLinked = selectedAddress.flatMap { IOBluetoothDevice(addressString: $0) }?.isConnected() ?? false
                teardown(next: stillLinked ? .failed("Connection lost: \(detail)") : .idle)
                return
            }
            if event == MDREvent(MDR_EVENT_NONE) { break }
            handle(event, device)
        }

        guard phase == .ready, mdrHeadphonesIsReady(device) == MDR_YES else { return }
        if mdrHeadphonesIsDirty(device) == MDR_YES {
            _ = mdrHeadphonesRequestCommit(device)
        } else if needSync || Date().timeIntervalSince(lastSync) > Self.batteryRefresh {
            needSync = false
            lastSync = Date()
            _ = mdrHeadphonesRequestSync(device, XM_SYNC_DEFAULT)
        }
    }

    private func handle(_ event: MDREvent, _ device: OpaquePointer) {
        switch event {
        case MDREvent(MDR_EVENT_INITIALIZE_COMPLETE):
            phase = .ready
            readIdentity(device)
            readCapabilities(device)
            readNoise(device)
            needSync = true // battery levels only arrive via sync; reading them now would show 0%
        case MDREvent(MDR_EVENT_IDENTITY_CHANGED):
            readIdentity(device)
        case MDREvent(MDR_EVENT_BATTERY_CHANGED), MDREvent(MDR_EVENT_SYNC_COMPLETE):
            readBatteries(device)
        case MDREvent(MDR_EVENT_NOISE_CONTROL_CHANGED), MDREvent(MDR_EVENT_APPLY_COMPLETE):
            readNoise(device)
        case MDREvent(MDR_EVENT_NEED_SYNC):
            needSync = true
        default:
            break
        }
    }

    // MARK: Reading state

    private func readIdentity(_ device: OpaquePointer) {
        modelName = mdrText(device, MDRText(MDR_TEXT_MODEL_NAME))
        firmware = mdrText(device, MDRText(MDR_TEXT_FIRMWARE_VERSION))
    }

    private func readCapabilities(_ device: OpaquePointer) {
        var modes: [NoiseMode] = [.off]
        if mdrHasFeature(device, MDRFeature(MDR_FEATURE_NOISE_CANCELLING)) { modes.append(.cancelling) }
        if mdrHasFeature(device, MDRFeature(MDR_FEATURE_AMBIENT_SOUND)) { modes.append(.ambient) }
        if mdrHasFeature(device, MDRFeature(MDR_FEATURE_WIND_NOISE_REDUCTION)) { modes.append(.windReduction) }
        availableModes = modes
        supportsAdaptiveAmbient = mdrHasFeature(device, MDRFeature(MDR_FEATURE_ADAPTIVE_AMBIENT_SOUND))
        if let lo = mdrValue(device, MDRValue(MDR_VALUE_AMBIENT_LEVEL_MIN)),
           let hi = mdrValue(device, MDRValue(MDR_VALUE_AMBIENT_LEVEL_MAX)), lo < hi {
            ambientRange = Int(lo)...Int(hi)
        }
    }

    private func readBatteries(_ device: OpaquePointer) {
        let labels = ["", "L", "R", "Case"]
        // libmdr reports 0% for parts the device hasn't reported yet (the case arrives a beat later).
        batteries = mdrBatteries(device).filter { $0.level_percent > 0 }.map {
            Battery(label: labels[safe: Int($0.part)] ?? "",
                    percent: Int($0.level_percent),
                    charging: $0.charging == MDRChargingState(MDR_CHARGING_YES))
        }
    }

    /// Shows the staged (DESIRED) values while a write is in flight, the device's (CURRENT) otherwise,
    /// so the UI neither lags the user's input nor misses changes made on the headphones.
    private func readNoise(_ device: OpaquePointer) {
        let type = mdrHeadphonesIsDirty(device) == MDR_YES ? PROPERTY_DESIRED : PROPERTY_CURRENT
        guard let nc = mdrNoiseControl(device, type) else { return }
        let mode: NoiseMode
        switch nc.mode {
        case MDRNoiseMode(MDR_NOISE_MODE_CANCELLING): mode = .cancelling
        case MDRNoiseMode(MDR_NOISE_MODE_AMBIENT): mode = .ambient
        case MDRNoiseMode(MDR_NOISE_MODE_WIND_NOISE_REDUCTION): mode = .windReduction
        default: mode = .off
        }
        noise = NoiseState(mode: mode, ambientLevel: Int(nc.ambient_level),
                           focusOnVoice: nc.focus_on_voice == MDR_YES, adaptive: nc.adaptive_ambient == MDR_YES)
    }

    // MARK: Writing state (staged now, committed by the event loop when the device is ready)

    private func updateNoise(_ change: (inout MDRNoiseControl) -> Void) {
        guard phase == .ready, let device, var nc = mdrNoiseControl(device, PROPERTY_DESIRED) else { return }
        change(&nc)
        guard mdrHeadphonesSetNoiseControl(device, &nc) == OK else { return }
        readNoise(device)
    }

    func setMode(_ mode: NoiseMode) {
        updateNoise {
            switch mode {
            case .off: $0.mode = MDRNoiseMode(MDR_NOISE_MODE_OFF)
            case .cancelling: $0.mode = MDRNoiseMode(MDR_NOISE_MODE_CANCELLING)
            case .ambient: $0.mode = MDRNoiseMode(MDR_NOISE_MODE_AMBIENT)
            case .windReduction: $0.mode = MDRNoiseMode(MDR_NOISE_MODE_WIND_NOISE_REDUCTION)
            }
        }
    }

    func setAmbientLevel(_ level: Int) {
        updateNoise {
            $0.ambient_level = UInt32(max(0, level))
            $0.adaptive_ambient = MDR_NO
        }
    }

    func setFocusOnVoice(_ on: Bool) {
        updateNoise { $0.focus_on_voice = on ? MDR_YES : MDR_NO }
    }

    func setAdaptiveAmbient(_ on: Bool) {
        updateNoise { $0.adaptive_ambient = on ? MDR_YES : MDR_NO }
    }

    // MARK: IOBluetooth notifications

    @objc private func bluetoothDeviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        refreshDevices()
        guard let addr = device.addressString.map(normalizeAddress) else { return }
        if selectedAddress == nil, devices.first(where: { $0.address == addr })?.looksLikeSony == true {
            selectedAddress = addr // didSet connects
            return
        }
        guard addr == selectedAddress else { return }
        // Give the headset a moment to bring up its control service after the audio link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectIfPossible() }
    }

    @objc private func bluetoothDeviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        teardown(next: .idle)
        refreshDevices()
    }
}
