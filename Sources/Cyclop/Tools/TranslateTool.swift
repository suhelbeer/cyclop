import SwiftUI

@MainActor
final class TranslateTool: NotchTool {
    let id: ToolID = "translate"
    let title = localized("Translate")
    let symbol = "translate"
    let rail = ToolRail.left
    let needsKeyboard = true

    let store = Translator()

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(TranslatePane(translator: store, wantsKeyboard: context.wantsKeyboard))
    }
}
