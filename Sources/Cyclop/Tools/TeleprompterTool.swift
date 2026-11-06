import Combine
import SwiftUI

@MainActor
final class TeleprompterTool: NotchTool {
    let id: ToolID = "teleprompter"
    let title = localized("Teleprompter")
    let symbol = "text.viewfinder"
    let rail = ToolRail.right
    let wantsTallBody = true

    let store = TeleprompterStore()

    // Only while there is nothing to read: an empty script is an editor, and an
    // editor a click can't put a caret into is a dead field.
    var clickTakesKeyboard: Bool { store.script.isEmpty }
    // Reading a script means not touching the trackpad, so a moving script
    // keeps the panel open.
    var holdsPanelOpen: Bool { store.isRunning }
    var holdsPanelOpenChanges: AnyPublisher<Void, Never> {
        store.$isRunning.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    }

    func suspend() { store.suspend() }
    func didLeave() { store.suspend() }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(TeleprompterPane(prompter: store, wantsKeyboard: context.wantsKeyboard))
    }
}
