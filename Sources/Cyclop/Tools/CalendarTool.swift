import SwiftUI

@MainActor
final class CalendarTool: NotchTool {
    let id: ToolID = "calendar"
    let title = localized("Calendar")
    let symbol = "calendar"
    let rail = ToolRail.left

    let store = CalendarStore()

    // Only picks up where it left off if access was granted earlier; it never
    // prompts on its own.
    func start() { store.start() }
    func stop() { store.stop() }
    func setPanelActive(_ active: Bool) { store.setActive(active) }
    func didEnter() { store.refreshAccess() }

    func headerAccessory() -> AnyView { AnyView(Countdown(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(CalendarPane(calendar: store, privacy: context.privacy))
    }

    private struct Countdown: View {
        @ObservedObject var store: CalendarStore
        var body: some View {
            if let next = store.next {
                Text(CalendarPane.countdown(to: next, from: store.now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(next.isRunning ? Color.white.opacity(0.8) : Theme.tertiary)
            }
        }
    }
}
