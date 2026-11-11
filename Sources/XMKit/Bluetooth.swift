import Foundation
import IOBluetooth

/// A Bluetooth device paired with this Mac, as seen by IOBluetooth.
public struct PairedDevice: Identifiable, Hashable {
    public let name: String
    /// Colon-separated, upper case, e.g. "58:18:62:73:7A:04".
    public let address: String
    public let isConnected: Bool
    public var id: String { address }

    /// Name-based guess, used only for ordering and default selection, never to block a device.
    public var looksLikeSony: Bool {
        let n = name.uppercased()
        return ["WH-", "WF-", "WI-", "MDR-", "LINKBUDS", "ULT WEAR", "INZONE"].contains { n.contains($0) }
    }

    /// Earbuds get a different menu bar symbol.
    public var isEarbuds: Bool {
        let n = name.uppercased()
        return n.hasPrefix("WF-") || n.contains("LINKBUDS")
    }
}

public func normalizeAddress(_ s: String) -> String {
    s.replacingOccurrences(of: "-", with: ":").uppercased()
}

/// Paired devices, Sony-looking ones first, then connected, then by name. Call on the main thread.
public func pairedDevices() -> [PairedDevice] {
    let raw = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return raw.compactMap { d -> PairedDevice? in
        guard let addr = d.addressString else { return nil }
        return PairedDevice(name: d.name ?? addr, address: normalizeAddress(addr), isConnected: d.isConnected())
    }
    .sorted {
        ($0.looksLikeSony ? 0 : 1, $0.isConnected ? 0 : 1, $0.name)
            < ($1.looksLikeSony ? 0 : 1, $1.isConnected ? 0 : 1, $1.name)
    }
}
