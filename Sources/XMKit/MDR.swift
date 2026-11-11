@_exported import CMDR
import Foundation

// Shared helpers over the libmdr C API, used by both the CLI and the menu bar app.

public struct XMError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public let OK = MDRResult(MDR_RESULT_OK)
public let IN_PROGRESS = MDRResult(MDR_RESULT_INPROGRESS)
public let TIMEOUT = MDRResult(MDR_RESULT_ERROR_TIMEOUT)
public let MDR_YES = MDRBoolean(MDR_TRUE)
public let MDR_NO = MDRBoolean(MDR_FALSE)

public func resultString(_ r: MDRResult) -> String { String(cString: mdrResultString(r)) }

public func check(_ r: MDRResult, _ what: String) throws {
    guard r == OK else { throw XMError("\(what): \(resultString(r))") }
}

/// The macOS backend schedules all IOBluetooth work on the main queue, and its
/// RFCOMM delegate callbacks arrive on the main run loop. A CLI has to pump it;
/// an app's run loop does this on its own.
public func pumpRunLoop(_ seconds: TimeInterval = 0.01) {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
}

/// Service UUID → protocol family. XM5/XM6 expose V2; XM4 and older expose V1.
public func protocolVersion(forService uuid: String) -> MDRProtocolVersion {
    uuid == MDR_SERVICE_UUID_V1 ? MDRProtocolVersion(MDR_PROTOCOL_V1) : MDRProtocolVersion(MDR_PROTOCOL_V2)
}

/// V2 first, then V1 — the order the reference client uses.
public let defaultServiceOrder = [MDR_SERVICE_UUID_V2, MDR_SERVICE_UUID_V1]

// MARK: Accessors on an `MDRHeadphones*`

public func mdrText(_ device: OpaquePointer, _ key: MDRText, index: UInt32 = 0) -> String? {
    var buffer = [CChar](repeating: 0, count: 512)
    var size = UInt32(buffer.count)
    guard mdrHeadphonesGetText(device, key, index, &buffer, &size) == OK else { return nil }
    let s = String(cString: buffer)
    return s.isEmpty ? nil : s
}

public func mdrHasFeature(_ device: OpaquePointer, _ f: MDRFeature) -> Bool {
    var availability = MDRFeatureAvailability(MDR_AVAILABILITY_UNKNOWN)
    return mdrHeadphonesGetFeature(device, f, &availability) == OK
        && availability == MDRFeatureAvailability(MDR_AVAILABILITY_AVAILABLE)
}

public func mdrValue(_ device: OpaquePointer, _ key: MDRValue, index: UInt32 = 0) -> Int32? {
    var v: Int32 = 0
    return mdrHeadphonesGetValue(device, key, index, &v) == OK ? v : nil
}

public func mdrBatteries(_ device: OpaquePointer) -> [MDRBattery] {
    var batteries = [MDRBattery](repeating: MDRBattery(), count: 4)
    var count = UInt32(batteries.count)
    guard mdrHeadphonesGetBatteries(device, &batteries, &count) == OK else { return [] }
    return Array(batteries.prefix(Int(count)))
}

public func mdrNoiseControl(_ device: OpaquePointer, _ type: MDRPropertyType) -> MDRNoiseControl? {
    var nc = MDRNoiseControl()
    return mdrHeadphonesGetNoiseControl(device, type, &nc) == OK ? nc : nil
}

public let PROPERTY_CURRENT = MDRPropertyType(MDR_PROPERTY_CURRENT)
public let PROPERTY_DESIRED = MDRPropertyType(MDR_PROPERTY_DESIRED)

// MARK: Logging

public var verbose = false
public func log(_ message: String) {
    if verbose { FileHandle.standardError.write("· \(message)\n".data(using: .utf8)!) }
}
