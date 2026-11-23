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

    // Phase 3: settings stored on the headphones (nil / empty when unsupported).
    @Published private(set) var equalizer: EqualizerInfo?
    @Published private(set) var speakToChat: SpeakToChatState?
    @Published private(set) var controls: [ControlInfo] = []
    @Published private(set) var power: PowerInfo?
    @Published private(set) var listening: ListeningInfo?

    // Phase 4: Mac integration.
    @Published private(set) var isSoundOutput = false
    @Published private(set) var bluetoothConnecting = false
    /// Transient message for the panel (a rejected write, a failed switch, …).
    @Published var notice: String?

    // Multipoint, now playing, wearing.
    @Published private(set) var peers: [HeadsetPeer] = [] {
        didSet { if peers != oldValue { NSLog("XMBar peers: %@", peers.map { "\($0.name)\($0.connected ? "+" : "")\($0.isPlaybackSource ? "*" : "")" }.joined(separator: ", ")) } }
    }
    /// nil when the headphones can't pin playback to one source.
    @Published private(set) var autoSourceSwitch: Bool?
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet { if nowPlaying != oldValue, let n = nowPlaying { NSLog("XMBar playback: %@ %@ – %@ vol %@", n.isPlaying ? "playing" : "\(n.status)", n.title ?? "-", n.artist ?? "-", n.volume.map(String.init) ?? "-") } }
    }
    @Published private(set) var wearing: Wearing? {
        didSet { if wearing != oldValue { NSLog("XMBar wearing: %@", String(describing: wearing)) } }
    }
    /// A confirmation the headphones are asking for (e.g. before a multipoint change).
    @Published private(set) var pendingAlert: String?
    private var pausedByRemoval = false
    let prefs = Preferences()
    private var batteryTracker = LowBatteryTracker()
    private var pendingOutputSwitch = false

    struct SpeakToChatState: Equatable {
        var enabled: Bool
        var sensitivity: MDRSpeechSensitivity
        var timeout: MDRSpeakTimeout
    }

    var selectedDevice: PairedDevice? { devices.first { $0.address == selectedAddress } }

    /// Lowest earbud/headphone level, for the menu bar title (the case doesn't count).
    var headlineBattery: Int? {
        debugBatteryOverride ?? batteries.filter { $0.label != "Case" }.map(\.percent).min()
    }
    /// Debug hooks only: pretend the battery is at this level (menu bar colour testing).
    @Published private(set) var debugBatteryOverride: Int?

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
        if debugHooks { installDebugHooks() }
        connectIfPossible()
    }

    // MARK: Debug hooks (launch with --debug-hooks)

    /// Lets scripts drive the same code paths as the panel's buttons, so UI behavior can be
    /// tested against real headphones without clicking. Off unless the app is launched with the flag.
    private let debugHooks = CommandLine.arguments.contains("--debug-hooks")

    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.xm-menubar.debug.setMode"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let name = note.object as? String else { return }
            let modes: [String: NoiseMode] = ["off": .off, "nc": .cancelling, "ambient": .ambient]
            guard let mode = modes[name] else { return }
            NSLog("XMBar debug: setMode(%@)", name)
            self.setMode(mode)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.xm-menubar.debug.playback"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let name = note.object as? String else { return }
            let actions: [String: UInt32] = ["play": MDR_PLAYBACK_PLAY, "pause": MDR_PLAYBACK_PAUSE,
                                             "next": MDR_PLAYBACK_NEXT, "previous": MDR_PLAYBACK_PREVIOUS]
            guard let a = actions[name] else { return }
            NSLog("XMBar debug: playback(%@)", name)
            self.playback(MDRPlaybackAction(a))
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.xm-menubar.debug.fakeBattery"), object: nil, queue: .main
        ) { [weak self] note in
            self?.debugBatteryOverride = (note.object as? String).flatMap(Int.init) // "" clears it
            NSLog("XMBar debug: fake battery %@", (note.object as? String) ?? "-")
        }
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
        equalizer = nil
        speakToChat = nil
        controls = []
        power = nil
        listening = nil
        peers = []
        autoSourceSwitch = nil
        nowPlaying = nil
        wearing = nil
        pendingAlert = nil
        pausedByRemoval = false
        batteryTracker.reset()
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
        if debugHooks, event != MDREvent(MDR_EVENT_UNHANDLED) { NSLog("XMBar event: %@", name(ofEvent: event)) }
        switch event {
        case MDREvent(MDR_EVENT_INITIALIZE_COMPLETE):
            phase = .ready
            readIdentity(device)
            readCapabilities(device)
            readNoise(device)
            readSettings(device)
            readConnectivity(device)
            needSync = true // battery levels only arrive via sync; reading them now would show 0%
            didBecomeReady()
        case MDREvent(MDR_EVENT_IDENTITY_CHANGED):
            readIdentity(device)
        case MDREvent(MDR_EVENT_BATTERY_CHANGED), MDREvent(MDR_EVENT_SYNC_COMPLETE):
            readBatteries(device)
        case MDREvent(MDR_EVENT_NOISE_CONTROL_CHANGED):
            readNoise(device)
        case MDREvent(MDR_EVENT_APPLY_COMPLETE):
            readNoise(device)
            readSettings(device)
            verifyPendingControl()
        case MDREvent(MDR_EVENT_EQUALIZER_CHANGED), MDREvent(MDR_EVENT_SPEAK_TO_CHAT_CHANGED),
             MDREvent(MDR_EVENT_ASSIGNABLE_CONTROLS_CHANGED), MDREvent(MDR_EVENT_POWER_CHANGED),
             MDREvent(MDR_EVENT_LISTENING_MODE_CHANGED):
            readSettings(device)
        case MDREvent(MDR_EVENT_PAIRED_DEVICES_CHANGED), MDREvent(MDR_EVENT_PAIRING_CHANGED):
            peers = readPeers(device)
            autoSourceSwitch = readAutoSourceSwitch(device, viewType(device))
        case MDREvent(MDR_EVENT_PLAYBACK_CHANGED):
            nowPlaying = readNowPlaying(device, viewType(device))
        case MDREvent(MDR_EVENT_WEARING_STATUS_CHANGED):
            let old = wearing
            wearing = readWearing(device)
            wearingChanged(from: old, to: wearing)
        case MDREvent(MDR_EVENT_ALERT):
            pendingAlert = mdrText(device, MDRText(MDR_TEXT_LAST_ALERT)) ?? "The headphones need confirmation."
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
        batteryTracker.update(batteries, threshold: prefs.lowBatteryThreshold,
                              device: modelName ?? selectedDevice?.name ?? "Headphones",
                              enabled: prefs.lowBatteryAlerts)
    }

    /// The property view the panel displays; see `readNoise` for why it is always DESIRED.
    private func viewType(_ device: OpaquePointer) -> MDRPropertyType { PROPERTY_DESIRED }

    private func readSettings(_ device: OpaquePointer) {
        let type = viewType(device)
        equalizer = readEqualizer(device, type)
        speakToChat = readSpeakToChat(device, type).map {
            SpeakToChatState(enabled: $0.enabled == MDR_YES, sensitivity: $0.sensitivity, timeout: $0.timeout)
        }
        controls = readControls(device, type)
        power = readPower(device, type)
        listening = readListening(device, type)
    }

    /// Always shows the DESIRED view. libmdr keeps it equal to the user's latest edit while a write is
    /// staged or in flight, and overwrites it with every device report once the property is clean
    /// (see MDRProperty::overwrite), so it also follows changes made on the headphones. CURRENT only
    /// moves on device reports, and some models don't report after accepting a write, which made the
    /// panel snap back to the previous mode after each change.
    private func readNoise(_ device: OpaquePointer) {
        guard let nc = mdrNoiseControl(device, viewType(device)) else { return }
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

    // MARK: Phase 3 writes

    /// Runs a staging write; the event loop commits it once the device is ready.
    private func stage(_ body: (OpaquePointer) throws -> Void) {
        guard phase == .ready, let device else { return }
        do {
            try body(device)
            notice = nil
        } catch {
            notice = "The headphones didn't accept that: \(error)"
        }
        readSettings(device)
    }

    func setEqualizerPreset(_ preset: MDREqualizerPreset) {
        stage { try check(mdrHeadphonesSetEqualizerPreset($0, preset), "SetEqualizerPreset") }
    }

    func setEqualizerBand(_ index: Int, to value: Int) {
        stage { device in
            guard var bands = readEqualizer(device, PROPERTY_DESIRED)?.bands, bands.indices.contains(index) else {
                return
            }
            bands[index] = value
            try stageEqualizerBands(device, bands)
        }
    }

    func resetEqualizerBands() {
        stage { device in
            guard let n = readEqualizer(device, PROPERTY_DESIRED)?.bands.count else { return }
            try stageEqualizerBands(device, Array(repeating: 0, count: n))
        }
    }

    func setClearBass(_ value: Int) {
        stage { try check(mdrHeadphonesSetEqualizerClearBass($0, Int32(value)), "SetEqualizerClearBass") }
    }

    func setDSEE(_ on: Bool) {
        stage { try check(mdrHeadphonesSetDSEE($0, on ? MDR_YES : MDR_NO), "SetDSEE") }
    }

    func setSpeakToChat(enabled: Bool? = nil, sensitivity: MDRSpeechSensitivity? = nil,
                        timeout: MDRSpeakTimeout? = nil) {
        stage { device in
            guard var stc = readSpeakToChat(device, PROPERTY_DESIRED) else { return }
            if let enabled { stc.enabled = enabled ? MDR_YES : MDR_NO }
            if let sensitivity { stc.sensitivity = sensitivity }
            if let timeout { stc.timeout = timeout }
            try check(mdrHeadphonesSetSpeakToChat(device, &stc), "SetSpeakToChat")
        }
    }

    func setControl(_ location: MDRAssignableActionKeyLocation, to action: MDRAssignableAction) {
        stage { try stageControl($0, location: location, action: action) }
        pendingControl = (location, action)
    }

    /// Some models (e.g. WF-1000XM6 on FW 2.0.5) ACK touch-control writes but keep the old mapping.
    /// After the write is applied, re-check and say so instead of silently snapping back.
    private var pendingControl: (MDRAssignableActionKeyLocation, MDRAssignableAction)?

    private func verifyPendingControl() {
        guard let (location, action) = pendingControl else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let device = self.device else { return }
            self.pendingControl = nil
            let current = readControls(device, PROPERTY_CURRENT).first { $0.location == location }?.action
            if current != action {
                self.notice = "\(self.modelName ?? "These headphones") didn't apply the touch control change. "
                    + "Use Sony's app to change touch controls on this model."
                self.readSettings(device)
            }
        }
    }

    func setAutoPowerOff(minutes: Int) {
        stage { device in
            guard var p = readPower(device, PROPERTY_DESIRED)?.raw else { return }
            p.auto_power_off_minutes = UInt32(minutes)
            try check(mdrHeadphonesSetPower(device, &p), "SetPower")
        }
    }

    func setPowerOffWhenRemoved(_ on: Bool) {
        stage { device in
            guard var p = readPower(device, PROPERTY_DESIRED)?.raw else { return }
            p.wearing_power = MDRWearingPowerMode(on ? MDR_WEARING_POWER_WHEN_REMOVED : MDR_WEARING_POWER_DISABLED)
            try check(mdrHeadphonesSetPower(device, &p), "SetPower")
        }
    }

    func setAutoPause(_ on: Bool) {
        stage { device in
            guard var p = readPower(device, PROPERTY_DESIRED)?.raw else { return }
            p.auto_pause = on ? MDR_YES : MDR_NO
            try check(mdrHeadphonesSetPower(device, &p), "SetPower")
        }
    }

    func setListeningMode(_ mode: MDRListeningMode) {
        stage { device in
            var l = MDRListening(mode: mode, background_room: MDRRoomSize(MDR_ROOM_UNKNOWN))
            try check(mdrHeadphonesSetListening(device, &l), "SetListening")
        }
    }

    // MARK: Multipoint, playback, wearing

    private func readConnectivity(_ device: OpaquePointer) {
        peers = readPeers(device)
        autoSourceSwitch = readAutoSourceSwitch(device, viewType(device))
        nowPlaying = readNowPlaying(device, viewType(device))
        wearing = readWearing(device)
    }

    /// Connect / disconnect a source device, or make it the one the headphones play from.
    func peerCommand(_ command: MDRPairedDeviceCommand, _ peer: HeadsetPeer) {
        stage { try stagePeerCommand($0, command, address: peer.address) }
    }

    func setAutoSourceSwitch(_ on: Bool) {
        stage { try check(mdrHeadphonesSetSourceSwitchControl($0, on ? MDR_YES : MDR_NO), "SetSourceSwitchControl") }
        if let device { autoSourceSwitch = readAutoSourceSwitch(device, PROPERTY_DESIRED) }
    }

    func answerAlert(_ accept: Bool) {
        stage {
            try check(mdrHeadphonesSetAlertResponse(
                $0, MDRAlertAction(accept ? MDR_ALERT_ACTION_POSITIVE : MDR_ALERT_ACTION_NEGATIVE)), "SetAlertResponse")
        }
        pendingAlert = nil
    }

    func playback(_ action: MDRPlaybackAction) {
        stage { try stagePlayback($0, action) }
        // The status only changes when the source reports back; show the intent right away.
        if var n = nowPlaying {
            if action == MDRPlaybackAction(MDR_PLAYBACK_PLAY) { n.status = MDRPlaybackStatus(MDR_PLAYBACK_PLAYING) }
            if action == MDRPlaybackAction(MDR_PLAYBACK_PAUSE) { n.status = MDRPlaybackStatus(MDR_PLAYBACK_PAUSED) }
            nowPlaying = n
        }
    }

    func setVolume(_ volume: Int) {
        stage { try check(mdrHeadphonesSetPlaybackVolume($0, UInt32(max(0, volume))), "SetPlaybackVolume") }
        if let device { nowPlaying = readNowPlaying(device, PROPERTY_DESIRED) }
    }

    /// Pauses when an earbud comes out while audio is playing, and resumes once both are back in,
    /// but only if we were the ones who paused. Commands go through the headphones, which forward
    /// them to whichever device is playing (Mac or phone), like a tap on the earbud would.
    private func wearingChanged(from old: Wearing?, to new: Wearing?) {
        guard prefs.pauseWhenRemoved, let new else { return }
        if new.removedCount > (old?.removedCount ?? 0), nowPlaying?.isPlaying == true {
            NSLog("XMBar: earbud removed while playing → pause")
            pausedByRemoval = true
            playback(MDRPlaybackAction(MDR_PLAYBACK_PAUSE))
        } else if new == .worn, pausedByRemoval {
            NSLog("XMBar: earbuds back in → resume")
            pausedByRemoval = false
            playback(MDRPlaybackAction(MDR_PLAYBACK_PLAY))
        }
    }

    // MARK: Phase 4: sound output & switching headphones

    func refreshSoundOutput() {
        guard let d = selectedDevice,
              let out = AudioOutput.device(forBluetoothAddress: d.address, name: d.name) else {
            isSoundOutput = false
            return
        }
        isSoundOutput = out.id == AudioOutput.defaultOutputID
    }

    /// Makes the selected headphones the Mac's sound output. The Bluetooth audio device can show up
    /// in CoreAudio a moment after the link, so this retries briefly.
    func useAsSoundOutput(attempts: Int = 4) {
        guard let d = selectedDevice else { return }
        if let out = AudioOutput.device(forBluetoothAddress: d.address, name: d.name) {
            if !AudioOutput.makeDefault(out) { notice = "macOS refused to switch the sound output." }
            refreshSoundOutput()
        } else if attempts > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.useAsSoundOutput(attempts: attempts - 1)
            }
        } else {
            notice = "\(d.name) isn't available as a sound output yet."
        }
    }

    /// Switches to other paired headphones: selects them, opens their Bluetooth link if needed
    /// (the control connection follows from the connect notification), and moves sound to them.
    func switchTo(_ address: String) {
        pendingOutputSwitch = true
        selectedAddress = address
        guard let d = selectedDevice, !d.isConnected, let bt = IOBluetoothDevice(addressString: address) else {
            return
        }
        bluetoothConnecting = true
        if bt.openConnection(self) != kIOReturnSuccess {
            bluetoothConnecting = false
            notice = "Couldn't reach \(d.name). Is it on and nearby?"
        }
    }

    /// IOBluetoothDevice async `openConnection(_:)` completion (informal protocol).
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        bluetoothConnecting = false
        if status != kIOReturnSuccess {
            notice = "Couldn't connect \(device?.name ?? "the headphones") (error \(status))."
        }
        refreshDevices()
    }

    private func didBecomeReady() {
        notice = nil
        refreshSoundOutput()
        NSLog("XMBar ready: eq=%@ bands=%@ dsee=%@ stc=%@ controls=%@ autoOff=%@ listening=%@ macOutput=%@",
              equalizer.map { describe(eqPreset: $0.preset) } ?? "-",
              equalizer.map { "\($0.bands)" } ?? "-",
              equalizer.map { $0.dseeAvailable ? "\($0.dseeEnabled)" : "n/a" } ?? "-",
              speakToChat.map { "\($0.enabled)" } ?? "-",
              controls.map { describe(assignableAction: $0.action) }.joined(separator: "/"),
              power.map { describe(autoOffMinutes: $0.minutes) } ?? "-",
              listening.map { describe(listeningMode: $0.mode) } ?? "-",
              "\(isSoundOutput)")
        if pendingOutputSwitch && prefs.autoSwitchOutput { useAsSoundOutput() }
        pendingOutputSwitch = false
    }

    // MARK: IOBluetooth notifications

    @objc private func bluetoothDeviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        refreshDevices()
        guard let addr = device.addressString.map(normalizeAddress) else { return }
        if selectedAddress == nil, devices.first(where: { $0.address == addr })?.looksLikeSony == true {
            pendingOutputSwitch = true
            selectedAddress = addr // didSet connects
            return
        }
        guard addr == selectedAddress else { return }
        pendingOutputSwitch = true
        if prefs.connectionAlerts {
            Notifier.post("Connected", "\(device.name ?? "Headphones") connected.", id: "connection")
        }
        // Give the headset a moment to bring up its control service after the audio link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectIfPossible() }
    }

    @objc private func bluetoothDeviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if prefs.connectionAlerts {
            Notifier.post("Disconnected", "\(device.name ?? "Headphones") disconnected.", id: "connection")
        }
        teardown(next: .idle)
        refreshDevices()
        refreshSoundOutput()
    }
}
