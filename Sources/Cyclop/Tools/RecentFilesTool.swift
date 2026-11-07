import SwiftUI

/// A row of the files that just arrived or were just used — downloads,
/// screenshots, anything opened lately — to click open or drag into any window.
@MainActor
final class RecentFilesTool: NotchTool {
    let id: ToolID = "recents"
    let title = localized("Recent")
    let symbol = "clock.arrow.circlepath"
    let rail = ToolRail.left

    let store = RecentFilesStore()

    func stop() { store.stop() }

    /// The panel opened again with this tool already showing: look again, the
    /// list has changed since it was folded away.
    func setPanelActive(_ active: Bool) {
        if active, store.isShown { store.refresh() }
    }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(RecentFilesPane(store: store))
    }

    private struct Counter: View {
        @ObservedObject var store: RecentFilesStore
        var body: some View { ToolCounter(value: store.items.count) }
    }
}
