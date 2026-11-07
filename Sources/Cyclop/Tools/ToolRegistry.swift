import Foundation

/// The one list of tools. The order inside a rail is the order here.
///
/// To add a tool: create `Tools/MyTool.swift` (see `NotchTool`) and add
/// `MyTool()` below.
@MainActor
enum ToolRegistry {
    static func makeAll() -> [any NotchTool] {
        [
            WindowsTool(),
            MusicTool(),
            ShelfTool(),
            RecentFilesTool(),
            ClipboardTool(),
            SnippetsTool(),
            CalendarTool(),
            TranslateTool(),
            NotesTool(),
            CurrencyTool(),
            TeleprompterTool(),
            UtilitiesTool(),
            SettingsTool(),
        ]
    }
}
