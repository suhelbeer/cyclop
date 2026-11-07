import CoreGraphics
import Testing
@testable import Cyclop

@MainActor
struct ClaudeBannerTests {
    /// The description of a real banner, measured on macOS 27.0.1.
    @Test func parsesClaudeBanner() {
        let parsed = ClaudeBannerWatcher.parse(description: "Claude, Sift app, Claude: The merges are underway in this order")
        #expect(parsed?.title == "Sift app")
        #expect(parsed?.body == "Claude: The merges are underway in this order")
    }

    @Test func ignoresOtherApps() {
        #expect(ClaudeBannerWatcher.parse(description: "Messages, Sam, See you at 6") == nil)
        #expect(ClaudeBannerWatcher.parse(description: "Claude Helper, x, y") == nil)
    }

    @Test func keepsCommasInTheBody() {
        let parsed = ClaudeBannerWatcher.parse(description: "Claude, notch-app, Claude: Done, 3 files changed, tests pass")
        #expect(parsed?.title == "notch-app")
        #expect(parsed?.body == "Claude: Done, 3 files changed, tests pass")
    }

    @Test func dropsClaudePrefix() {
        #expect(ClaudeBannerWatcher.clean("Claude: Needs your approval") == "Needs your approval")
        #expect(ClaudeBannerWatcher.clean("  Plain message ") == "Plain message")
    }

    private let windows: [(id: CGWindowID, name: String)] = [
        (1, "Claude"), (2, "Accent coach app"), (3, "notch-app"),
    ]

    @Test func matchesProjectWindowByName() {
        #expect(ClaudeStatusMonitor.window(for: "Accent coach app", in: windows) == 2)
        #expect(ClaudeStatusMonitor.window(for: "Notch-App", in: windows) == 3)
    }

    /// A project without its own window lives in the main window.
    @Test func unknownProjectGoesToMainWindow() {
        #expect(ClaudeStatusMonitor.window(for: "Sift app", in: windows) == 1)
        #expect(ClaudeStatusMonitor.window(for: "Sift app", in: [(2, "Accent coach app")]) == nil)
    }
}
