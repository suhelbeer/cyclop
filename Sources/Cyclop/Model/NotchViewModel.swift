import AppKit
import Combine

/// State shared by every screen's panel: which tool is selected, which are
/// switched on, and the tools themselves. The tools own their data; this class
/// only routes between them and never names an individual one (see `NotchTool`).
@MainActor
final class NotchViewModel: ObservableObject {
    /// Every tool, in registry order.
    let tools: [any NotchTool]
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    /// What every screen's panel adds up to, kept by `NotchController`: this
    /// model is shared by all of them and has no panel of its own. Plain
    /// properties, because nothing on screen reads them — a view asks its own
    /// `PanelState` about its own display.
    private(set) var isPanelActive = false
    var isTyping = false
    private var started = false

    // MARK: - Lookup

    func tool(_ id: ToolID) -> (any NotchTool)? { tools.first { $0.id == id } }

    func tool<T: NotchTool>(_ type: T.Type) -> T? { tools.compactMap { $0 as? T }.first }

    /// The selected tool. Never nil: `tab` is always one of `tools`.
    var activeTool: any NotchTool { tool(tab) ?? tools[0] }

    // MARK: - Which tools are on the rail

    /// Tools switched off in Settings. Off means two things: the icon leaves
    /// the rail, and the tool's background work stops with it. Kept as the set
    /// of what is off rather than what is on, so a tool added in a later
    /// version shows up for everyone instead of arriving hidden. Persisted in
    /// `config.json` under `hiddenTabs`.
    @Published private(set) var hiddenTabs: Set<ToolID>

    func isVisible(_ id: ToolID) -> Bool { !hiddenTabs.contains(id) }

    var visibleTools: [any NotchTool] { tools.filter { isVisible($0.id) } }
    var leftRail: [any NotchTool] { visibleTools.filter { $0.rail == .left } }
    var rightRail: [any NotchTool] { visibleTools.filter { $0.rail == .right } }

    /// Where to land when the tool on screen is the one being taken away.
    private var firstVisibleTool: ToolID {
        (leftRail.first ?? rightRail.first ?? tools[0]).id
    }

    func setVisible(_ id: ToolID, _ visible: Bool) {
        guard let target = tool(id), target.canHide, isVisible(id) != visible else { return }
        if visible {
            hiddenTabs.remove(id)
            if started {
                target.start()
                if isPanelActive { target.setPanelActive(true) }
            }
        } else {
            hiddenTabs.insert(id)
            target.stop()
            // Done before the icon goes, so the pane never shows a tool the
            // rail no longer has.
            if tab == id { tab = firstVisibleTool }
        }
        ConfigStore.shared.hiddenTabs = hiddenTabs.map(\.rawValue).sorted()
        ConfigStore.shared.enabledTabs = tools
            .filter { !$0.enabledByDefault && isVisible($0.id) }
            .map { $0.id.rawValue }.sorted()
    }

    /// Whether any screen shows more than the bare notch. Tools whose clocks
    /// exist only for an open panel follow this, and only while switched on.
    func setPanelActive(_ active: Bool) {
        guard active != isPanelActive else { return }
        isPanelActive = active
        for tool in visibleTools { tool.setPanelActive(active) }
    }

    // MARK: - Selection

    @Published var tab: ToolID {
        didSet {
            guard tab != oldValue else { return }
            tool(oldValue)?.didLeave()
            tool(tab)?.didEnter()
            // Leaving the tool that types gives the keyboard straight back —
            // done per screen, where the claim lives, in `NotchScreenPanel`.
        }
    }

    /// Whether a click into the panel should hand it the keyboard.
    var clickTakesKeyboard: Bool { activeTool.clickTakesKeyboard }

    /// Whether the panel must stay open with no pointer on it. The one
    /// exception to "the pointer decides"; see `NotchTool.holdsPanelOpen`.
    var holdsOpen: Bool { activeTool.holdsPanelOpen }

    /// A tool somewhere is holding the panel open (the screen pin is chosen by
    /// the controller from this).
    var anyToolHoldsOpen: Bool { visibleTools.contains { $0.holdsPanelOpen } }

    /// Merged "something that can pin the panel changed" signal.
    var holdChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(tools.map(\.holdsPanelOpenChanges)).eraseToAnyPublisher()
    }

    func suspendAll() { tools.forEach { $0.suspend() } }

    // MARK: - Lifecycle

    init() {
        let tools = ToolRegistry.makeAll()
        precondition(Set(tools.map(\.id)).count == tools.count, "duplicate tool id")
        self.tools = tools
        var hidden = Set<ToolID>()
        let saved = Set(ConfigStore.shared.hiddenTabs.map { ToolID($0) })
        let enabled = Set(ConfigStore.shared.enabledTabs.map { ToolID($0) })
        for tool in tools where tool.canHide {
            // Off if the user switched it off, or it ships off and they have not switched it on.
            if saved.contains(tool.id) || (!tool.enabledByDefault && !enabled.contains(tool.id)) {
                hidden.insert(tool.id)
            }
        }
        self.hiddenTabs = hidden
        let first = tools.first { !hidden.contains($0.id) && $0.rail == .left }
            ?? tools.first { !hidden.contains($0.id) }
            ?? tools[0]
        self.tab = first.id
    }

    func start() {
        wireScreenshots()
        started = true
        for tool in visibleTools { tool.start() }
        // The selected tool may have been switched off in a previous session.
        if !isVisible(tab) { tab = firstVisibleTool }
    }

    func stop() {
        started = false
        for tool in tools { tool.stop() }
    }

    // MARK: - Cross-tool wiring

    /// Off switch for people who copy images all day and do not want them
    /// kept. Persisted in `config.json`.
    static var saveClipboardImagesEnabled: Bool {
        get { ConfigStore.shared.saveClipboardImages }
        set { ConfigStore.shared.saveClipboardImages = newValue }
    }

    /// Screenshots reach the shelf whether they were taken on this Mac, copied
    /// to the clipboard, or taken on a phone and carried over by Continuity.
    /// The one place two tools know about each other; both are optional.
    private func wireScreenshots() {
        guard let shelf = tool(ShelfTool.self) else { return }
        if let clipboard = tool(ClipboardTool.self) {
            // Images are kept only for the shelf, so a shelf that is
            // switched off takes none.
            clipboard.store.wantsImages = { [weak self] in
                Self.saveClipboardImagesEnabled && (self?.isVisible(shelf.id) ?? false)
            }
            clipboard.store.onImage = { [weak self] png in
                guard let self, let url = ScreenshotVault.save(png) else { return }
                self.receivedScreenshot(at: url)
            }
        }
        shelf.screenshotFolder.onImage = { [weak self] url in
            self?.receivedScreenshot(at: url)
        }
    }

    /// A screenshot that arrived on its own rather than one the user handed to
    /// the panel. It goes on the shelf either way, but only switches to showing
    /// it when nobody is mid-sentence.
    func receivedScreenshot(at url: URL) {
        guard let shelf = tool(ShelfTool.self), isVisible(shelf.id) else { return }
        shelf.store.add([url])
        guard !isTyping else { return }
        tab = shelf.id
    }

    // MARK: - File drops

    /// The tool that takes files dropped on the panel, if any is switched on.
    var dropTarget: (any NotchTool)? {
        visibleTools.first { $0.acceptsFileDrops }
    }

    /// A file the user dropped by hand: switching to the receiving tool is the
    /// point. Refused when no tool takes files.
    /// A scroll over the notch, offered to the visible tools in rail order.
    func notchScrolled(_ event: NSEvent) -> Bool {
        visibleTools.contains { $0.notchScrolled(event) }
    }

    func accept(urls: [URL]) -> Bool {
        guard let target = dropTarget, target.acceptDrop(urls) else { return false }
        tab = target.id
        return true
    }
}
