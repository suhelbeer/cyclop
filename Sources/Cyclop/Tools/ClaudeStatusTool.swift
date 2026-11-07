import Combine
import SwiftUI

/// Claude desktop app status in the notch: a dot per Claude window left of
/// the camera (by default whenever Claude is open, optionally only while one
/// is working, waiting on you or finished), and a pane listing them all. A click on a dot or a row jumps to the window.
///
/// Read-only towards Claude; see `ClaudeStatusMonitor` for the rules.
@MainActor
final class ClaudeStatusTool: NotchTool {
    let id: ToolID = "claude-status"
    let title = localized("Claude")
    let symbol = "sparkle"
    let rail = ToolRail.left

    let monitor = ClaudeStatusMonitor()

    var bodySize: ToolBodySize { .compact }

    func start() { monitor.start() }
    func stop() { monitor.stop() }

    // MARK: - Live activity

    var activity: NotchActivity? {
        guard monitor.showsDots else { return nil }
        return NotchActivity(wingWidth: ClaudeDots.width(for: monitor.windows.count), caption: monitor.caption)
    }

    var activityChanges: AnyPublisher<Void, Never> {
        monitor.objectWillChange
            // `objectWillChange` fires before the value moves; read it a pass later.
            .receive(on: DispatchQueue.main)
            .map { [weak self] _ in MainActor.assumeIsolated { self?.activity } }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func activityWing() -> AnyView { AnyView(ClaudeDots(monitor: monitor)) }

    // MARK: - Pane

    func headerAccessory() -> AnyView { AnyView(Waiting(monitor: monitor)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(ClaudeStatusPane(monitor: monitor))
    }

    /// How many windows have something new waiting on you.
    private struct Waiting: View {
        @ObservedObject var monitor: ClaudeStatusMonitor
        var body: some View {
            ToolCounter(value: monitor.windows.filter { $0.activity == .needsInput }.count)
        }
    }
}
