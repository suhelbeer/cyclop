import SwiftUI

/// Claude Code sessions running on this Mac: which project, whether each is
/// working, done or waiting on you, and a click to jump to its terminal.
@MainActor
final class ClaudeSessionsTool: NotchTool {
    let id: ToolID = "claudeSessions"
    let title = localized("Claude")
    let symbol = "sparkle"
    let rail = ToolRail.left

    let store = ClaudeSessionStore()

    func start() { store.start() }
    func stop() { store.stop() }
    func setPanelActive(_ active: Bool) { store.setPanelActive(active) }

    func headerAccessory() -> AnyView { AnyView(Badge(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(ClaudeSessionsPane(store: store))
    }

    /// Sessions waiting on you, in orange, or else how many are running.
    private struct Badge: View {
        @ObservedObject var store: ClaudeSessionStore
        var body: some View {
            if store.needsYouCount > 0 {
                Text("\(store.needsYouCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
            } else {
                ToolCounter(value: store.sessions.count)
            }
        }
    }
}
