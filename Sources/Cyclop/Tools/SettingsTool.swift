import SwiftUI

@MainActor
final class SettingsTool: NotchTool {
    let id: ToolID = "settings"
    let title = localized("Settings")
    let symbol = "gearshape.fill"
    let rail = ToolRail.right
    let wantsTallBody = true
    // With Settings gone there would be no way back to the switches.
    let canHide = false

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(SettingsPane(vm: context.vm))
    }
}
