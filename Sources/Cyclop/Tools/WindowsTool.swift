import SwiftUI

/// Windows attached to the notch: a live preview of each, a bigger one for
/// the window under the pointer, and a click to jump to it. Claude desktop
/// app windows are attached by default. Arrange lines them up in a strip you
/// move along from the notch (`WindowStrip`).
@MainActor
final class WindowsTool: NotchTool {
    let id: ToolID = "windows"
    let title = localized("Windows")
    let symbol = "macwindow.on.rectangle"
    let rail = ToolRail.left
    let wantsTallBody = true

    let store = WindowStore()

    // Capture runs only while the panel is open and this pane is on screen;
    // the pane reports its own visibility.
    func setPanelActive(_ active: Bool) { store.panelActive = active }
    func stop() {
        store.panelActive = false
        // Never leave windows parked off screen behind a quit or a switch-off.
        WindowStrip.shared.releaseNow()
    }

    func notchScrolled(_ event: NSEvent) -> Bool { WindowStrip.shared.scrolled(event) }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(WindowsPane(store: store))
    }

    private struct Counter: View {
        @ObservedObject var store: WindowStore
        var body: some View { ToolCounter(value: store.attached.count) }
    }
}
