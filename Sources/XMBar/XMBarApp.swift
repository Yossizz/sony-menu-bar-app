import SwiftUI

@main
struct XMBarApp: App {
    @StateObject private var controller = HeadphonesController()

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
        let symbol = controller.selectedDevice?.isEarbuds == true ? "earbuds" : "headphones"
        if controller.phase == .ready, let pct = controller.headlineBattery {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text("\(pct)%").monospacedDigit()
            }
        } else {
            Image(systemName: symbol)
                .opacity(controller.phase == .ready ? 1 : 0.5)
        }
    }
}
