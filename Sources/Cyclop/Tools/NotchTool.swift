import Combine
import SwiftUI

/// Stable name of a tool. Stored in `config.json` (`hiddenTabs`), so a value
/// must never change once a release has shipped it.
struct ToolID: Hashable, ExpressibleByStringLiteral, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
}

/// Which group a tool belongs to: left is for what gets a glance between other
/// things, right is for the rarer modes and Settings. The icon row beside the
/// notch no longer splits by this (see `NotchViewModel.notchRow`); it still
/// orders the Settings list.
enum ToolRail { case left, right }

/// How much room a tool's pane asks for under the icon row. See
/// `NotchGeometry.paneSize(for:)` for the numbers.
enum ToolBodySize: Equatable {
    /// A short strip: one block of content, like Now Playing.
    case compact
    case standard
    /// Same width, twice the height: a script, a long settings list.
    case tall
    /// Wider and taller, for rows of window previews with a large one below.
    case wide
    /// As wide, one row of previews high, plus whatever lines of status sit
    /// under the row right now — measured by the tool, so there is no black
    /// band kept in reserve for lines that are not showing.
    case wideRow(extraHeight: CGFloat)

    /// The sizes that do not depend on a tool's state; the window is cut to
    /// fit the largest of them.
    static let fixed: [ToolBodySize] = [.compact, .standard, .tall, .wide]
}

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
    /// Room the pane gets under the icon row. Defaults to `.tall` for a tool
    /// that wants a tall body and `.standard` otherwise.
    var bodySize: ToolBodySize { get }
    /// Fires when `bodySize` may have changed while the tool is showing.
    var bodySizeChanges: AnyPublisher<Void, Never> { get }
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
    /// A scroll over the notch itself (the top band of the panel, open or
    /// folded). Return true to take it; the first visible tool that does wins.
    func notchScrolled(_ event: NSEvent) -> Bool

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
    var bodySize: ToolBodySize { wantsTallBody ? .tall : .standard }
    var bodySizeChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var canHide: Bool { true }
    var enabledByDefault: Bool { true }
    var holdsPanelOpen: Bool { false }
    var holdsPanelOpenChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var acceptsFileDrops: Bool { false }
    func acceptDrop(_ urls: [URL]) -> Bool { false }
    func notchScrolled(_ event: NSEvent) -> Bool { false }

    func start() {}
    func stop() {}
    func setPanelActive(_ active: Bool) {}
    func didEnter() {}
    func didLeave() {}
    func suspend() {}

    func headerAccessory() -> AnyView { AnyView(EmptyView()) }
}
