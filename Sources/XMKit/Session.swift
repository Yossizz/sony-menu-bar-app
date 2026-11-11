import Foundation
import IOBluetooth

/// Blocking, CLI-style session: one RFCOMM connection to one pair of headphones,
/// driven from the main thread by pumping the run loop. The menu bar app uses the
/// non-blocking `HeadphonesController` instead.
public final class Session {
    private let backend: OpaquePointer // MDRConnectionMacOS*
    public let conn: UnsafeMutablePointer<MDRConnection>
    public private(set) var device: OpaquePointer? // MDRHeadphones*
    public private(set) var protocolVersion: MDRProtocolVersion = 0
    public var onEvent: ((MDREvent) -> Void)?

    public init() {
        backend = mdrConnectionMacOSCreate()
        conn = mdrConnectionMacOSGet(backend)
    }

    deinit {
        if let device { mdrHeadphonesDestroy(device) }
        mdrConnectionDisconnect(conn)
        pumpRunLoop(0.2) // let the queued disconnect run before the backend goes away
        mdrConnectionMacOSDestroy(backend)
    }

    public var lastConnectionError: String { String(cString: mdrConnectionGetLastError(conn)) }

    // MARK: Connection

    public enum ProtocolChoice { case auto, v1, v2 }

    public func connect(address: String, protocol choice: ProtocolChoice, timeout: TimeInterval = 10) throws {
        let services: [String]
        switch choice {
        case .auto: services = defaultServiceOrder
        case .v1: services = [MDR_SERVICE_UUID_V1]
        case .v2: services = [MDR_SERVICE_UUID_V2]
        }
        // The control channel rides on an existing audio link; fail fast with a clear message.
        if let bt = IOBluetoothDevice(addressString: address), !bt.isConnected() {
            throw XMError("\(bt.name ?? address) is paired but not connected to this Mac — "
                + "take it out of the case / connect it in Bluetooth settings, then retry")
        }
        var failures: [String] = []
        for uuid in services {
            let label = uuid == MDR_SERVICE_UUID_V1 ? "V1" : "V2"
            if openChannel(address: address, uuid: uuid, timeout: timeout, failures: &failures, label: label) {
                protocolVersion = XMKit.protocolVersion(forService: uuid)
                log("connected over \(label) service")
                return
            }
        }
        throw XMError("could not connect to \(address): " + failures.joined(separator: "; "))
    }

    private func openChannel(address: String, uuid: String, timeout: TimeInterval,
                             failures: inout [String], label: String) -> Bool {
        log("connecting to \(address) via \(label) service \(uuid)…")
        var r = mdrConnectionConnect(conn, address, uuid)
        if r == OK || r == IN_PROGRESS {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while true {
                pumpRunLoop(0.02)
                r = mdrConnectionPoll(conn, 0)
                if r == OK { return true }
                if r != IN_PROGRESS && r != TIMEOUT { break }
                if Date() >= deadline { r = TIMEOUT; break }
            }
        }
        let detail = lastConnectionError
        failures.append("\(label): \(detail.isEmpty ? resultString(r) : detail)")
        mdrConnectionDisconnect(conn)
        pumpRunLoop(0.2)
        return false
    }

    // MARK: Protocol session

    public func start(trace: Bool, timeout: TimeInterval = 20) throws {
        var dev: OpaquePointer?
        let r = mdrHeadphonesCreate(XM_ABI_VERSION, conn, protocolVersion, &dev)
        guard r == OK, let dev else { throw XMError("mdrHeadphonesCreate: \(resultString(r))") }
        device = dev
        if trace {
            mdrDebugSetPacketCallback(dev, { _, direction, _, frame, size in
                guard let frame else { return }
                let bytes = UnsafeBufferPointer(start: frame, count: Int(size))
                let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let arrow = direction == MDRPacketDirection(MDR_PACKET_DIRECTION_TX) ? "TX >" : "RX <"
                FileHandle.standardError.write("\(arrow) \(hex)\n".data(using: .utf8)!)
            }, nil)
        }
        try check(mdrHeadphonesRequestInit(dev, XM_INIT_DEFAULT), "RequestInit")
        try waitFor(MDREvent(MDR_EVENT_INITIALIZE_COMPLETE), timeout: timeout, what: "initialization")
    }

    /// Pumps the run loop and the protocol state machine until `target` is reported.
    public func waitFor(_ target: MDREvent, timeout: TimeInterval, what: String) throws {
        guard let device else { throw XMError("not started") }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            pumpRunLoop()
            var event = MDREvent(MDR_EVENT_NONE)
            let r = mdrHeadphonesPoll(device, &event)
            guard r == OK else {
                throw XMError("\(what) failed: \(resultString(r)) — \(mdrText(device, MDRText(MDR_TEXT_LAST_ERROR)) ?? "")")
            }
            if event != MDREvent(MDR_EVENT_NONE) {
                onEvent?(event)
                if event == target { return }
            }
        }
        throw XMError("\(what) timed out after \(Int(timeout))s")
    }

    /// Pulls states the device doesn't push on init (battery levels, playback, wearing status).
    public func sync(_ flags: MDRHeadphonesSyncFlags = XM_SYNC_DEFAULT, timeout: TimeInterval = 10) throws {
        guard let device else { throw XMError("not started") }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while mdrHeadphonesIsReady(device) != MDR_YES {
            guard Date() < deadline else { throw XMError("device busy, cannot sync") }
            try drain(0.05)
        }
        try check(mdrHeadphonesRequestSync(device, flags), "RequestSync")
        try waitFor(MDREvent(MDR_EVENT_SYNC_COMPLETE), timeout: timeout, what: "sync")
    }

    /// Keeps processing events for `seconds` (used to catch follow-up state reports).
    public func drain(_ seconds: TimeInterval) throws {
        guard let device else { return }
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            pumpRunLoop()
            var event = MDREvent(MDR_EVENT_NONE)
            try check(mdrHeadphonesPoll(device, &event), "Poll")
            if event != MDREvent(MDR_EVENT_NONE) { onEvent?(event) }
        }
    }

    public func commit(timeout: TimeInterval = 10) throws {
        guard let device else { throw XMError("not started") }
        try check(mdrHeadphonesRequestCommit(device), "RequestCommit")
        try waitFor(MDREvent(MDR_EVENT_APPLY_COMPLETE), timeout: timeout, what: "apply")
    }

    // MARK: Accessors

    public func text(_ key: MDRText, index: UInt32 = 0) -> String? {
        device.flatMap { mdrText($0, key, index: index) }
    }

    public func feature(_ f: MDRFeature) -> Bool {
        device.map { mdrHasFeature($0, f) } ?? false
    }

    public func value(_ key: MDRValue, index: UInt32 = 0) -> Int32? {
        device.flatMap { mdrValue($0, key, index: index) }
    }
}
