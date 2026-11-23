import SwiftUI

@main
struct XMBarApp: App {
    @StateObject private var controller = HeadphonesController()

    init() {
        IconPreview.renderIfRequested() // debug: `--render-icons <dir>` writes PNGs and exits
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(controller)
        } label: {
            MenuBarLabel(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: HeadphonesController

    var body: some View {
        let icon = Image(nsImage: MenuBarIcon.image(for: ProductKind(device: controller.selectedDevice)))
        if controller.phase == .ready, let pct = controller.headlineBattery {
            HStack(spacing: 3) {
                icon
                if let color = lowBatteryColor(pct) {
                    Image(nsImage: MenuBarIcon.coloredPercent(pct, color: color))
                } else {
                    Text("\(pct)%").monospacedDigit()
                }
            }
        } else {
            icon.opacity(controller.phase == .ready ? 1 : 0.5)
        }
    }
}

extension MenuBarLabel {
    /// Red at 10% or below, orange at or below the low-battery threshold, nil (normal) otherwise.
    func lowBatteryColor(_ percent: Int) -> NSColor? {
        if percent <= 10 { return .systemRed }
        if percent <= controller.prefs.lowBatteryThreshold { return .systemOrange }
        return nil
    }
}
