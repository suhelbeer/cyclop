import SwiftUI
import Testing
@testable import Cyclop

/// The registry is the one place tools are listed, so these guard the rules
/// the rest of the app relies on. Panel layout stays untested, as before.
@MainActor
struct ToolRegistryTests {
    /// A tool that sets only what is required — proves the defaults.
    private final class Bare: NotchTool {
        let id: ToolID = "bare"
        let title = "Bare"
        let symbol = "circle"
        let rail = ToolRail.left
        func pane(_ context: ToolContext) -> AnyView { AnyView(EmptyView()) }
    }

    @Test func defaultsAreInert() {
        let tool = Bare()
        #expect(!tool.needsKeyboard)
        #expect(!tool.clickTakesKeyboard)
        #expect(!tool.wantsTallBody)
        #expect(tool.bodySize == .standard)
        #expect(tool.canHide)
        #expect(!tool.holdsPanelOpen)
        #expect(!tool.acceptsFileDrops)
        #expect(!tool.acceptDrop([]))
    }

    @Test func idsAreUnique() {
        let ids = ToolRegistry.makeAll().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Settings holds the switches: it must stay on the rail and reachable.
    @Test func settingsCannotBeHidden() throws {
        let settings = try #require(ToolRegistry.makeAll().first { $0.id == "settings" })
        #expect(!settings.canHide)
    }

    /// Persisted in `config.json`; renaming one silently resets a user's switch.
    @Test func shippedIdsStayPut() {
        let ids = Set(ToolRegistry.makeAll().map(\.id.rawValue))
        for shipped in ["media", "shelf", "clipboard", "snippets", "calendar", "translate",
                        "notes", "currency", "teleprompter", "utilities", "settings", "recents"] {
            #expect(ids.contains(shipped))
        }
    }
}

extension ToolRegistryTests {
    @Test func currencyShipsOff() throws {
        let currency = try #require(ToolRegistry.makeAll().first { $0.id == "currency" })
        #expect(!currency.enabledByDefault)
    }
}
