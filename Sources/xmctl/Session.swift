import CMDR
import Foundation
import IOBluetooth

struct XMError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

let OK = MDRResult(MDR_RESULT_OK)
let IN_PROGRESS = MDRResult(MDR_RESULT_INPROGRESS)
let TIMEOUT = MDRResult(MDR_RESULT_ERROR_TIMEOUT)

func resultString(_ r: MDRResult) -> String { String(cString: mdrResultString(r)) }

/// The macOS backend schedules all IOBluetooth work on the main queue, and its
/// RFCOMM delegate callbacks arrive on the main run loop. A CLI has to pump it.
func pumpRunLoop(_ seconds: TimeInterval = 0.01) {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
}

/// One RFCOMM connection to one pair of headphones, driven from the main thread.
final class Session {
    private let backend: OpaquePointer // MDRConnectionMacOS*
    let conn: UnsafeMutablePointer<MDRConnection>
    private(set) var device: OpaquePointer? // MDRHeadphones*
    private(set) var protocolVersion: MDRProtocolVersion = 0
    var onEvent: ((MDREvent) -> Void)?

    init() {
        backend = mdrConnectionMacOSCreate()
        conn = mdrConnectionMacOSGet(backend)
    }

    deinit {
        if let device { mdrHeadphonesDestroy(device) }
        mdrConnectionDisconnect(conn)
        pumpRunLoop(0.2) // let the queued disconnect run before the backend goes away
        mdrConnectionMacOSDestroy(backend)
    }

    var lastConnectionError: String { String(cString: mdrConnectionGetLastError(conn)) }

    // MARK: Discovery

    struct PairedDevice { let name: String; let address: String }

    func pairedDevices(timeout: TimeInterval = 5) throws -> [PairedDevice] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var list: UnsafeMutablePointer<MDRDeviceInfo>?
        var count: Int32 = 0
        while true {
            let r = mdrConnectionGetDevicesList(conn, &list, &count)
            if r == OK { break }
            guard r == IN_PROGRESS else { throw XMError("device list failed: \(resultString(r))") }
            guard Date() < deadline else { throw XMError("device list timed out") }
            pumpRunLoop()
        }
        defer { mdrConnectionFreeDevicesList(conn, &list) }
        guard let list else { return [] }
        return (0..<Int(count)).map { i in
            var info = list[i]
            let name = withUnsafeBytes(of: &info.szDeviceName) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let addr = withUnsafeBytes(of: &info.szDeviceMacAddress) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return PairedDevice(name: name, address: addr)
        }
    }

    // MARK: Connection

    enum ProtocolChoice { case auto, v1, v2 }

    /// Opens RFCOMM to the device. XM5/XM6 expose the V2 SDP service; XM4 and older expose V1.
    /// `.auto` tries V2 first, then V1 — the same order the reference client uses.
    func connect(address: String, protocol choice: ProtocolChoice, timeout: TimeInterval = 10) throws {
        let services: [String]
        switch choice {
        case .auto: services = [MDR_SERVICE_UUID_V2, MDR_SERVICE_UUID_V1]
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
            if try openChannel(address: address, uuid: uuid, timeout: timeout, failures: &failures, label: label) {
                protocolVersion = uuid == MDR_SERVICE_UUID_V1 ? MDRProtocolVersion(MDR_PROTOCOL_V1)
                                                              : MDRProtocolVersion(MDR_PROTOCOL_V2)
                log("connected over \(label) service")
                return
            }
        }
        throw XMError("could not connect to \(address): " + failures.joined(separator: "; "))
    }

    private func openChannel(address: String, uuid: String, timeout: TimeInterval,
                             failures: inout [String], label: String) throws -> Bool {
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

    func start(trace: Bool, timeout: TimeInterval = 20) throws {
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
    func waitFor(_ target: MDREvent, timeout: TimeInterval, what: String) throws {
        guard let device else { throw XMError("not started") }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            pumpRunLoop()
            var event = MDREvent(MDR_EVENT_NONE)
            let r = mdrHeadphonesPoll(device, &event)
            guard r == OK else {
                throw XMError("\(what) failed: \(resultString(r)) — \(text(MDRText(MDR_TEXT_LAST_ERROR)) ?? "")")
            }
            if event != MDREvent(MDR_EVENT_NONE) {
                onEvent?(event)
                if event == target { return }
            }
        }
        throw XMError("\(what) timed out after \(Int(timeout))s")
    }

    /// Pulls states the device doesn't push on init (battery levels, playback, wearing status).
    func sync(_ flags: MDRHeadphonesSyncFlags = XM_SYNC_DEFAULT, timeout: TimeInterval = 10) throws {
        guard let device else { throw XMError("not started") }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while mdrHeadphonesIsReady(device) != MDRBoolean(MDR_TRUE) {
            guard Date() < deadline else { throw XMError("device busy, cannot sync") }
            try drain(0.05)
        }
        try check(mdrHeadphonesRequestSync(device, flags), "RequestSync")
        try waitFor(MDREvent(MDR_EVENT_SYNC_COMPLETE), timeout: timeout, what: "sync")
    }

    /// Keeps processing events for `seconds` (used to catch follow-up state reports).
    func drain(_ seconds: TimeInterval) throws {
        guard let device else { return }
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            pumpRunLoop()
            var event = MDREvent(MDR_EVENT_NONE)
            try check(mdrHeadphonesPoll(device, &event), "Poll")
            if event != MDREvent(MDR_EVENT_NONE) { onEvent?(event) }
        }
    }

    func commit(timeout: TimeInterval = 10) throws {
        guard let device else { throw XMError("not started") }
        try check(mdrHeadphonesRequestCommit(device), "RequestCommit")
        try waitFor(MDREvent(MDR_EVENT_APPLY_COMPLETE), timeout: timeout, what: "apply")
    }

    // MARK: Accessors

    func text(_ key: MDRText, index: UInt32 = 0) -> String? {
        guard let device else { return nil }
        var buffer = [CChar](repeating: 0, count: 512)
        var size = UInt32(buffer.count)
        guard mdrHeadphonesGetText(device, key, index, &buffer, &size) == OK else { return nil }
        let s = String(cString: buffer)
        return s.isEmpty ? nil : s
    }

    func feature(_ f: MDRFeature) -> Bool {
        guard let device else { return false }
        var availability = MDRFeatureAvailability(MDR_AVAILABILITY_UNKNOWN)
        return mdrHeadphonesGetFeature(device, f, &availability) == OK
            && availability == MDRFeatureAvailability(MDR_AVAILABILITY_AVAILABLE)
    }

    func value(_ key: MDRValue, index: UInt32 = 0) -> Int32? {
        guard let device else { return nil }
        var v: Int32 = 0
        return mdrHeadphonesGetValue(device, key, index, &v) == OK ? v : nil
    }

    func check(_ r: MDRResult, _ what: String) throws {
        guard r == OK else { throw XMError("\(what): \(resultString(r))") }
    }
}

var verbose = false
func log(_ message: String) {
    if verbose { FileHandle.standardError.write("· \(message)\n".data(using: .utf8)!) }
}
