import Foundation
import ServiceManagement
import UserNotifications

/// User preferences for app behavior (not headphone settings; those live on the headphones).
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var lowBatteryAlerts: Bool { didSet { defaults.set(lowBatteryAlerts, forKey: "lowBatteryAlerts") } }
    @Published var lowBatteryThreshold: Int {
        didSet { defaults.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") }
    }
    @Published var connectionAlerts: Bool { didSet { defaults.set(connectionAlerts, forKey: "connectionAlerts") } }
    @Published var autoSwitchOutput: Bool { didSet { defaults.set(autoSwitchOutput, forKey: "autoSwitchOutput") } }
    @Published var pauseWhenRemoved: Bool { didSet { defaults.set(pauseWhenRemoved, forKey: "pauseWhenRemoved") } }

    // Launch at login lives in macOS (SMAppService), mirrored here for the UI.
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published private(set) var loginMessage: String?

    func setLaunchAtLogin(_ on: Bool) {
        loginMessage = LaunchAtLogin.set(on)
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    }

    init() {
        defaults.register(defaults: [
            "lowBatteryAlerts": true, "lowBatteryThreshold": 20,
            "connectionAlerts": false, "autoSwitchOutput": true, "pauseWhenRemoved": true,
        ])
        lowBatteryAlerts = defaults.bool(forKey: "lowBatteryAlerts")
        lowBatteryThreshold = defaults.integer(forKey: "lowBatteryThreshold")
        connectionAlerts = defaults.bool(forKey: "connectionAlerts")
        autoSwitchOutput = defaults.bool(forKey: "autoSwitchOutput")
        pauseWhenRemoved = defaults.bool(forKey: "pauseWhenRemoved")
    }
}

/// Launch at login via the macOS 13 login-item API for the app itself.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns an error message to show, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on && needsApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Allow XMBar in System Settings → General → Login Items."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Banner notifications. Permission is requested the first time something is posted.
enum Notifier {
    private static var authorized: Bool?

    static func post(_ title: String, _ body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if authorized == true { send(); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
            if granted { send() }
        }
    }
}

/// Fires one low-battery alert per part each time it drops below the threshold,
/// re-arming once it charges back above threshold + 5%.
struct LowBatteryTracker {
    private var alerted: Set<String> = []

    mutating func update(_ batteries: [HeadphonesController.Battery], threshold: Int, device: String,
                         enabled: Bool) {
        for b in batteries where b.label != "Case" {
            let key = b.label
            if b.charging || b.percent > threshold + 5 {
                alerted.remove(key)
            } else if b.percent <= threshold, !alerted.contains(key) {
                alerted.insert(key)
                if enabled {
                    let part = b.label.isEmpty ? device : "\(device) (\(b.label == "L" ? "left" : "right"))"
                    Notifier.post("Low battery", "\(part) is at \(b.percent)%.", id: "battery-\(key)")
                }
            }
        }
    }

    mutating func reset() { alerted = [] }
}
