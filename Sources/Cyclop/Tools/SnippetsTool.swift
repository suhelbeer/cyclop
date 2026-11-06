import SwiftUI

@MainActor
final class SnippetsTool: NotchTool {
    let id: ToolID = "snippets"
    let title = localized("Snippets")
    let symbol = "pin.fill"
    let rail = ToolRail.left
    let needsKeyboard = true

    let store = SnippetStore()

    func start() { store.reload() }
    // The snippets file is edited from outside the app, so it is read on the
    // way in rather than held from launch.
    func didEnter() { store.reload() }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(SnippetsPane(snippets: store, privacy: context.privacy, wantsKeyboard: context.wantsKeyboard))
    }

    private struct Counter: View {
        @ObservedObject var store: SnippetStore
        var body: some View { ToolCounter(value: store.items.count) }
    }
}
