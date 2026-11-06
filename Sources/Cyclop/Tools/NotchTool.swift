import Combine
import SwiftUI

/// Stable name of a tool. Stored in `config.json` (`hiddenTabs`), so a value
/// must never change once a release has shipped it.
struct ToolID: Hashable, ExpressibleByStringLiteral, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
}

/// Which column of icons a tool sits in. Left is for what gets a glance between
/// other things, right is for the rarer modes and Settings.
enum ToolRail { case left, right }

/// What the panel hands a tool when it draws the tool's pane.
@MainActor
struct ToolContext {
    unowned let vm: NotchViewModel
    let privacy: PrivacyMode
    /// A tool with a text field flips this to take the keyboard.
    let wantsKeyboard: Binding<Bool>
    /// True while a file is being dragged over the panel.
    let isDropTargeted: Bool
}

/// One tab of the panel.
///
/// **Adding a tool is one file plus one line.** Write a class that conforms to
/// this protocol (only `id`, `title`, `symbol`, `rail` and `pane` are
/// required) and add it to `ToolRegistry.makeAll()`. Nothing else in the app
/// names individual tools: the rail, the Settings switches, the lifecycle and
/// the persisted on/off state all follow the registry.
///
/// A tool owns its own state, so a hidden tool costs nothing: `start()` runs
/// only while the tool is switched on, and `stop()` when it is switched off.
@MainActor
protocol NotchTool: AnyObject {
    // MARK: Identity
    var id: ToolID { get }
    var title: String { get }
    /// SF Symbol name for the rail icon.
    var symbol: String { get }
    var rail: ToolRail { get }

    // MARK: Behaviour (all optional)
    /// Tabs with a text field. Landing on one hands it the keyboard.
    var needsKeyboard: Bool { get }
    /// Whether a click into the panel should (re)claim the keyboard.
    var clickTakesKeyboard: Bool { get }
    /// Wants more than the standard body height.
    var wantsTallBody: Bool { get }
    /// False for a tool that can't be switched off (Settings: it holds the switches).
    var canHide: Bool { get }
    /// False for a tool that ships switched off. The user turns it on in Settings.
    var enabledByDefault: Bool { get }
    /// Panel stays open with no pointer on it while this is true.
    var holdsPanelOpen: Bool { get }
    /// Fires when `holdsPanelOpen` may have changed.
    var holdsPanelOpenChanges: AnyPublisher<Void, Never> { get }
    /// Accepts files dropped on the panel. The first visible tool that says yes wins.
    var acceptsFileDrops: Bool { get }
    func acceptDrop(_ urls: [URL]) -> Bool

    // MARK: Lifecycle (all optional)
    /// Background work. Called when the tool is on and the app starts, or when
    /// it is switched back on.
    func start()
    /// Stop everything `start()` began. Also called at quit.
    func stop()
    /// The panel opened or fully folded away anywhere.
    func setPanelActive(_ active: Bool)
    /// This tool became / stopped being the selected tab.
    func didEnter()
    func didLeave()
    /// The panel folded on the screen this tool was pinning open.
    func suspend()

    // MARK: Views
    /// Small trailing item in the header strip (a counter, a date). Optional.
    func headerAccessory() -> AnyView
    func pane(_ context: ToolContext) -> AnyView
}

extension NotchTool {
    var needsKeyboard: Bool { false }
    var clickTakesKeyboard: Bool { needsKeyboard }
    var wantsTallBody: Bool { false }
    var canHide: Bool { true }
    var enabledByDefault: Bool { true }
    var holdsPanelOpen: Bool { false }
    var holdsPanelOpenChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var acceptsFileDrops: Bool { false }
    func acceptDrop(_ urls: [URL]) -> Bool { false }

    func start() {}
    func stop() {}
    func setPanelActive(_ active: Bool) {}
    func didEnter() {}
    func didLeave() {}
    func suspend() {}

    func headerAccessory() -> AnyView { AnyView(EmptyView()) }
}
