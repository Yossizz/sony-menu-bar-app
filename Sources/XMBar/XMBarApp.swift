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
                Text("\(pct)%").monospacedDigit()
            }
        } else {
            icon.opacity(controller.phase == .ready ? 1 : 0.5)
        }
    }
}
