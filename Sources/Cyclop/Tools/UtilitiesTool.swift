import SwiftUI

@MainActor
final class UtilitiesTool: NotchTool {
    let id: ToolID = "utilities"
    let title = localized("Utilities")
    let symbol = "wrench.and.screwdriver.fill"
    let rail = ToolRail.right

    /// Here rather than in the pane: the lock is a system-wide mode and must
    /// outlive plugging a monitor in mid-wipe.
    let keyboardLock = KeyboardLock()

    // Taking the tab off the rail with the screen still covered would leave the
    // tap installed and no way back to it.
    func stop() { keyboardLock.unlock() }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(UtilitiesPane(lock: keyboardLock))
    }
}
