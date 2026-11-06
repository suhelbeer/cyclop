import SwiftUI

@MainActor
final class ClipboardTool: NotchTool {
    let id: ToolID = "clipboard"
    let title = localized("Clipboard")
    let symbol = "list.clipboard.fill"
    let rail = ToolRail.left

    let store = ClipboardStore()

    func start() { store.start() }
    func stop() { store.stop() }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(ClipboardPane(clipboard: store, privacy: context.privacy))
    }

    private struct Counter: View {
        @ObservedObject var store: ClipboardStore
        var body: some View { ToolCounter(value: store.items.count) }
    }
}

/// The small number in the header strip, shared by tools that count things.
struct ToolCounter: View {
    let value: Int

    var body: some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}
