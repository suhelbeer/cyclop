import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The same private call `WindowFocus` uses, declared again so the strip's
/// worker can run it off the main actor.
@_silgen_name("_AXUIElementGetWindow")
private func stripWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The attached windows laid side by side in a strip you scroll along, like
/// a scrolling window manager, but only for the windows attached to the notch.
///
/// Limits, on purpose: the current desktop only (Accessibility cannot reach
/// windows on others) and the built-in display only. It does not defend the
/// layout: if macOS or another tool moves a window, Arrange again or Release.
/// The one change it does pick up is a window's edge dragged by hand, which
/// becomes that column's width.
@MainActor
final class WindowStrip: ObservableObject {
    static let shared = WindowStrip()

    /// Why an attached window was left out.
    enum Reason: Equatable {
        case minimized, fullScreen, hidden, otherDesktop, noResponse, addedLater

        var text: String {
            switch self {
            case .minimized: localized("minimized")
            case .fullScreen: localized("full screen")
            case .hidden: localized("app hidden")
            case .otherDesktop: localized("on another desktop")
            case .noResponse: localized("not responding")
            case .addedLater: localized("opened after Arrange")
            }
        }
    }

    struct Left: Identifiable, Equatable {
        let window: AttachedWindow
        let reason: Reason
        var id: CGWindowID { window.id }
    }

    @Published private(set) var columns: [StripLayout.Column] = []
    @Published private(set) var focus = 0
    /// Columns shown in full right now.
    @Published private(set) var inView: Set<CGWindowID> = []
    @Published private(set) var leftOut: [Left] = []
    @Published private(set) var note: String?

    var isArranged: Bool { !columns.isEmpty }
    var focusedID: CGWindowID? { columns.indices.contains(focus) ? columns[focus].id : nil }
    func index(of id: CGWindowID) -> Int? { columns.firstIndex { $0.id == id } }

    // Changeable later from Settings; overridable now through `defaults`.
    let previousKey = Shortcut.stored("strip.shortcut.previous",
                                      default: Shortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: Shortcut.control | Shortcut.option))
    let nextKey = Shortcut.stored("strip.shortcut.next",
                                  default: Shortcut(keyCode: UInt32(kVK_RightArrow), modifiers: Shortcut.control | Shortcut.option))
    let widthKey = Shortcut.stored("strip.shortcut.width",
                                   default: Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: Shortcut.control | Shortcut.option))
    let centerKey = Shortcut.stored("strip.shortcut.center",
                                    default: Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: Shortcut.control | Shortcut.option))
    let narrowerKey = Shortcut.stored("strip.shortcut.narrower",
                                      default: Shortcut(keyCode: UInt32(kVK_ANSI_Minus), modifiers: Shortcut.control | Shortcut.option))
    let widerKey = Shortcut.stored("strip.shortcut.wider",
                                   default: Shortcut(keyCode: UInt32(kVK_ANSI_Equal), modifiers: Shortcut.control | Shortcut.option))

    private var windows: [CGWindowID: AttachedWindow] = [:]
    /// Frames from before Arrange, for Release.
    private var original: [CGWindowID: CGRect] = [:]
    /// What was last asked of each window, so unchanged ones are not moved.
    private var applied: [CGWindowID: CGRect] = [:]
    private var failures: [CGWindowID: Int] = [:]
    /// Where the view sits along the strip, in points from its start.
    private var offset: CGFloat = 0
    private var area: CGRect = .zero
    private var hotKeys: [UInt32] = []
    private var scroll = ScrollStepper()
    private let mover = StripMover()

    /// A trackpad swipe in progress: the strip follows the fingers until it
    /// ends, then settles on the nearest column.
    private struct Swipe {
        let startOffset: CGFloat
        let horizontal: Bool
        var travel: CGFloat = 0
        var frames: [CGWindowID: CGRect] = [:]
        var lastEvent = Date()
    }
    private var swipe: Swipe?

    /// One operation at a time, in order: a key held down queues steps
    /// faster than windows can move, and they are folded together.
    private enum Op {
        case arrange([AttachedWindow]), step(Int), focus(CGWindowID), move(CGWindowID, Int), cycleWidth, release
        /// End of a swipe: where the view stopped, and where the windows are.
        case rest(CGFloat, [CGWindowID: CGRect])
        case center
        /// Focused window a step narrower (-1) or wider (+1).
        case nudgeWidth(Int)
        /// A window's edge was dragged by hand.
        case resized(CGWindowID)
    }
    private var queue: [Op] = []
    private var draining = false
    /// When the strip last moved focus itself. Until the raise has landed, the
    /// app in front may still report the previous window as focused.
    private var lastOwnFocus = Date.distantPast
    private var raiseGeneration = 0

    // MARK: - Commands

    /// Lines up `windows` (the tab's order) or, if already arranged, lines
    /// them up again keeping each window's width and original frame.
    func arrange(_ windows: [AttachedWindow]) {
        guard WindowFocus.hasAccess else {
            WindowFocus.requestAccess()
            note = localized("Allow Accessibility to move windows")
            return
        }
        enqueue(.arrange(windows))
    }

    func release() { enqueue(.release) }
    func step(_ delta: Int) { if isArranged { enqueue(.step(delta)) } }
    func focus(on id: CGWindowID) { if isArranged { enqueue(.focus(id)) } }
    func cycleWidth() { if isArranged { enqueue(.cycleWidth) } }
    /// Puts the focused window in the middle, its neighbours showing either side.
    func center() { if isArranged { enqueue(.center) } }
    func nudgeWidth(_ direction: Int) { if isArranged { enqueue(.nudgeWidth(direction)) } }
    /// Puts a window at another place in the strip, from a drag in the previews.
    func move(_ id: CGWindowID, to index: Int) { if isArranged { enqueue(.move(id, index)) } }

    /// A scroll over the notch, or one the scroll tap claimed. True when it
    /// was used.
    func scrolled(_ event: NSEvent, starting: Bool = false) -> Bool {
        guard isArranged else { return false }
        // A trackpad gesture is followed continuously; a mouse wheel steps.
        if event.hasPreciseScrollingDeltas, !event.phase.isEmpty || !event.momentumPhase.isEmpty || swipe != nil {
            follow(event, starting: starting)
            return true
        }
        let delta = scroll.step(
            dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            began: starting || event.phase.contains(.began),
            momentum: !event.momentumPhase.isEmpty
        )
        if delta != 0 { step(delta) }
        return true
    }

    /// Follows the fingers, then the glide macOS adds after they lift, like
    /// any scrolling view. The strip comes to rest where the glide stops.
    private func follow(_ event: NSEvent, starting: Bool) {
        let gliding = !event.momentumPhase.isEmpty
        // A glide belongs to the swipe before it; without one there is nothing to continue.
        if gliding, swipe == nil { return }
        let begins = starting || event.phase.contains(.began) || event.phase.contains(.mayBegin)
        if begins, swipe != nil { endSwipe() }
        if swipe == nil {
            guard !event.phase.contains(.ended), !event.phase.contains(.cancelled) else { return }
            swipe = Swipe(startOffset: offset, horizontal: abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY))
            // Windows leaving on the left have to slide under their right-hand
            // neighbours, so stack them that way round. On its own queue: it
            // must not hold up the first moves.
            mover.restack(columns.compactMap { windows[$0.id] }, focus: nil)
            watchSwipe()
        }
        guard var current = swipe else { return }
        current.travel += current.horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        current.lastEvent = Date()
        let widths = StripLayout.widths(columns, in: area)
        let shown = StripLayout.rubberBand(
            current.startOffset - current.travel,
            max: StripLayout.maxOffset(widths: widths, available: area.width)
        )
        let frames = StripLayout.frames(columns, offset: shown, in: area)
        var targets: [(AttachedWindow, CGPoint)] = []
        for (column, frame) in zip(columns, frames) {
            current.frames[column.id] = frame
            if let window = windows[column.id] { targets.append((window, frame.origin)) }
        }
        swipe = current
        mover.place(targets)
        // Lifting the fingers starts the glide (if the swipe was quick enough
        // to have one); the swipe ends with the glide, or shortly after the
        // fingers if no glide comes.
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { endSwipe() }
    }

    /// Ends a swipe once its events stop: after the fingers lift with no glide,
    /// or when the pointer left the notch mid-way and the end never came.
    private func watchSwipe() {
        Task { @MainActor [weak self] in
            while let self, let swipe = self.swipe {
                if Date().timeIntervalSince(swipe.lastEvent) > 0.12 {
                    self.endSwipe()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The strip stays where the fingers stopped (pulled back inside its ends
    /// if it was stretched past one).
    private func endSwipe() {
        guard let done = swipe else { return }
        swipe = nil
        enqueue(.rest(done.startOffset - done.travel, done.frames))
    }

    /// Windows that disappeared leave the strip; the rest close ranks.
    func windowsChanged(_ attached: [AttachedWindow]) {
        guard isArranged else { return }
        let live = Set(attached.map(\.id))
        for window in attached where windows[window.id] != nil { windows[window.id] = window }
        let gone = columns.filter { !live.contains($0.id) }.map(\.id)
        let known = Set(columns.map(\.id)).union(leftOut.map(\.id))
        let added = attached.filter { !known.contains($0.id) }.map { Left(window: $0, reason: .addedLater) }
        leftOut.removeAll { !live.contains($0.id) }
        if !added.isEmpty { leftOut += added }
        guard !gone.isEmpty else { return }
        drop(gone)
        if isArranged { enqueue(.step(0)) }
    }

    /// Puts every window back right away, on the calling thread. For quitting
    /// and switching the tab off, when there is no later to finish in.
    func releaseNow() {
        guard isArranged || !original.isEmpty else { return }
        mover.stop()
        for (id, frame) in original {
            guard let window = windows[id] else { continue }
            _ = StripAX.setFrame(frame, of: window)
        }
        reset()
    }

    // MARK: - Queue

    private func enqueue(_ op: Op) {
        queue.append(op)
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while !queue.isEmpty {
                let op = queue.removeFirst()
                switch op {
                case .step(let delta):
                    // Fold the steps that piled up behind this one.
                    var total = delta
                    while case .step(let more)? = queue.first {
                        total += more
                        queue.removeFirst()
                    }
                    await performStep(total)
                case .arrange(let list): await performArrange(list)
                case .focus(let id): await performFocus(id)
                case .move(let id, let index): await performMove(id, to: index)
                case .cycleWidth: await performCycleWidth()
                case .release: await performRelease()
                case .rest(let stop, let frames): await performRest(stop, frames)
                case .center: await performCenter()
                case .nudgeWidth(let direction): await performNudgeWidth(direction)
                case .resized(let id): await performResized(id)
                }
            }
            draining = false
        }
    }

    // MARK: - Operations

    private func performArrange(_ list: [AttachedWindow]) async {
        guard let screen = Self.stripScreen, let primary = NSScreen.screens.first else { return }
        let target = WindowLayout.accessibilityRect(from: screen.visibleFrame, primaryHeight: primary.frame.height)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hidden = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))

        let probes = await Task.detached(priority: .userInitiated) {
            list.map { window -> (AttachedWindow, StripAX.Probe) in
                hidden.contains(window.pid) ? (window, .hidden) : (window, StripAX.probe(window))
            }
        }.value
        let focusedNow: CGWindowID? = if let frontPID {
            await Task.detached { StripAX.focusedWindowID(pid: frontPID) }.value
        } else { nil }

        let previous = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        var next: [StripLayout.Column] = []
        var left: [Left] = []
        for (window, probe) in probes {
            switch probe {
            case .frame(let frame):
                windows[window.id] = window
                if original[window.id] == nil { original[window.id] = frame }
                next.append(previous[window.id] ?? StripLayout.Column(id: window.id))
            case .minimized: left.append(Left(window: window, reason: .minimized))
            case .fullScreen: left.append(Left(window: window, reason: .fullScreen))
            case .hidden: left.append(Left(window: window, reason: .hidden))
            case .unreachable: left.append(Left(window: window, reason: .otherDesktop))
            }
        }
        leftOut = left
        guard !next.isEmpty else {
            note = localized("No attached window on this desktop can be arranged")
            if columns.isEmpty { reset(keepNote: true, keepLeftOut: true) }
            return
        }
        let wasArranged = isArranged
        let wasFocused = focusedID
        columns = next
        area = target
        applied = [:]
        failures = [:]
        if let focusedNow, let index = index(of: focusedNow) {
            focus = index
        } else if let wasFocused, let index = index(of: wasFocused) {
            focus = index
        } else {
            focus = 0
        }
        if !wasArranged { offset = 0 }
        note = nil
        registerHotKeys()
        await layout()
        raiseFocused()
        StripResizeWatcher.shared.onResize = { [weak self] id in self?.enqueue(.resized(id)) }
        StripResizeWatcher.shared.watch(columns.compactMap { windows[$0.id] })
    }

    private func performStep(_ delta: Int) async {
        guard isArranged else { return }
        await followRealFocus()
        let target = min(max(focus + delta, 0), columns.count - 1)
        let moved = target != focus
        focus = target
        await layout()
        if moved || delta == 0 { raiseFocused() }
    }

    /// The window nearest the middle takes focus; the view does not move to
    /// show it whole, it stays where the swipe left it.
    private func performRest(_ stop: CGFloat, _ frames: [CGWindowID: CGRect]) async {
        guard isArranged else { return }
        let widths = StripLayout.widths(columns, in: area)
        offset = StripLayout.avoidPeek(
            StripLayout.clamp(stop, widths: widths, available: area.width), widths: widths, available: area.width
        )
        focus = StripLayout.nearestToCenter(widths: widths, offset: offset, available: area.width)
        // The swipe moved the windows; slide on from where it left them.
        applied.merge(frames) { $1 }
        await layout(reveal: false)
        raiseFocused()
    }

    private func performNudgeWidth(_ direction: Int) async {
        guard isArranged else { return }
        await followRealFocus()
        let current = StripLayout.width(of: columns[focus], in: area)
        columns[focus].custom = StripLayout.nudged(current, by: direction, in: area)
        columns[focus].minWidth = 0
        await layout()
        raiseFocused()
    }

    private func performCenter() async {
        guard isArranged else { return }
        await followRealFocus()
        await layout(center: true)
        raiseFocused()
    }

    /// A window whose edge was dragged keeps the width it was given, and its
    /// neighbours move to fit. Its height goes back to the strip's.
    private func performResized(_ id: CGWindowID) async {
        guard let index = index(of: id), let window = windows[id], let asked = applied[id] else { return }
        let actual = await Task.detached { StripAX.frame(of: window) }.value
        guard let actual, abs(actual.width - asked.width) > 3 else { return }
        columns[index].custom = actual.width
        columns[index].minWidth = 0
        focus = index
        // Pretend it was asked for, so only a different height or place moves it.
        applied[id] = actual
        await layout()
    }

    private func performFocus(_ id: CGWindowID) async {
        guard let index = index(of: id) else { return }
        focus = index
        await layout()
        raiseFocused()
    }

    /// The focused window stays focused wherever it ends up; the view follows
    /// it, so the window just moved may slide out of view if it went far.
    private func performMove(_ id: CGWindowID, to index: Int) async {
        guard let from = self.index(of: id) else { return }
        let to = min(max(index, 0), columns.count - 1)
        guard to != from else { return }
        let focused = focusedID
        columns = StripLayout.moving(columns, from: from, to: to)
        focus = focused.flatMap(self.index(of:)) ?? focus
        await layout()
        raiseFocused()
    }

    private func performCycleWidth() async {
        guard isArranged else { return }
        await followRealFocus()
        // From a width set by hand, back to the preset it came from.
        if columns[focus].custom != nil {
            columns[focus].custom = nil
        } else {
            columns[focus].preset = StripLayout.nextPreset(after: columns[focus].preset)
        }
        // A window that refused a narrow width may manage a wider one; let it try.
        columns[focus].minWidth = 0
        await layout()
        raiseFocused()
    }

    private func performRelease() async {
        let restore = original.compactMap { id, frame in windows[id].map { ($0, frame) } }
        mover.stop()
        reset()
        await Task.detached(priority: .userInitiated) {
            for (window, frame) in restore { _ = StripAX.setFrame(frame, of: window) }
        }.value
    }

    // MARK: - Layout

    /// Places every column, then reads back what the windows actually did.
    /// A window that would not go as narrow as asked keeps its real width and
    /// the strip is laid out again around it.
    ///
    /// Windows that only move slide there; windows that change size are set at
    /// once (a resize makes the app redraw, which cannot be animated smoothly).
    /// With `reveal` the view moves to show the focused column (in the middle
    /// with `center`); without, it stays where it is.
    private func layout(reveal: Bool = true, center: Bool = false) async {
        for _ in 0..<3 {
            guard isArranged else { return }
            let widths = StripLayout.widths(columns, in: area)
            offset = reveal
                ? StripLayout.reveal(focus, widths: widths, offset: offset, available: area.width, center: center)
                : StripLayout.clamp(offset, widths: widths, available: area.width)
            let frames = StripLayout.frames(columns, offset: offset, in: area)
            let shown = StripLayout.visible(widths: widths, offset: offset, available: area.width)
            inView = Set(shown.map { columns[$0].id })
            var resizes: [(AttachedWindow, CGRect)] = []
            var slides: [(AttachedWindow, CGRect)] = []
            for (column, frame) in zip(columns, frames) where applied[column.id] != frame {
                guard let window = windows[column.id] else { continue }
                if applied[column.id]?.size == frame.size {
                    slides.append((window, frame))
                } else {
                    resizes.append((window, frame))
                }
            }
            if !slides.isEmpty {
                mover.slide(slides.map { ($0.0, $0.1.origin) })
                for (window, frame) in slides { applied[window.id] = frame }
            }
            guard !resizes.isEmpty else { return }
            let results = await Task.detached(priority: .userInitiated) {
                resizes.map { window, frame in (window.id, frame, StripAX.setFrame(frame, of: window)) }
            }.value

            var relayout = false
            var lost: [CGWindowID] = []
            for (id, asked, actual) in results {
                guard let actual else {
                    failures[id, default: 0] += 1
                    applied[id] = nil
                    if failures[id, default: 0] >= 2 { lost.append(id) }
                    continue
                }
                failures[id] = nil
                applied[id] = asked
                mover.note([id: asked.origin])
                guard let index = index(of: id) else { continue }
                if actual.width > asked.width + 1, actual.width > columns[index].minWidth + 1 {
                    columns[index].minWidth = actual.width
                    relayout = true
                }
            }
            if !lost.isEmpty {
                for id in lost {
                    if let window = windows[id] { leftOut.append(Left(window: window, reason: .noResponse)) }
                }
                drop(lost)
                relayout = true
            }
            guard relayout else { return }
        }
    }

    private func drop(_ ids: [CGWindowID]) {
        let focused = focusedID
        columns.removeAll { ids.contains($0.id) }
        for id in ids { applied[id] = nil }
        guard isArranged else {
            reset(keepLeftOut: true)
            return
        }
        // The column to the right of a removed focused one takes its place.
        focus = focused.flatMap(index(of:)) ?? min(focus, columns.count - 1)
        // Shown columns shift left; let them all be placed again.
        applied = [:]
    }

    /// If the user clicked a window in the strip since the strip last moved,
    /// steps start from that window instead.
    private func followRealFocus() async {
        guard Date().timeIntervalSince(lastOwnFocus) > 1,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              columns.contains(where: { windows[$0.id]?.pid == pid })
        else { return }
        let id = await Task.detached { StripAX.focusedWindowID(pid: pid) }.value
        if let id, let index = index(of: id) { focus = index }
    }

    /// Makes the focused column the key window, after stacking the others
    /// left to right so a window parked at the left edge stays under its
    /// neighbour. Raised, then its app made active, then raised once more after
    /// activation has settled: activating can bring the app's previous front
    /// window back on top.
    private func raiseFocused() {
        guard let id = focusedID, let window = windows[id] else { return }
        lastOwnFocus = Date()
        raiseGeneration += 1
        let generation = raiseGeneration
        mover.restack(columns.compactMap { windows[$0.id] }, focus: window)
        Task { @MainActor in
            guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isActive else { return }
            WindowFocus.activate(app)
            try? await Task.sleep(for: .milliseconds(150))
            guard generation == raiseGeneration else { return }
            mover.restack([], focus: window)
        }
    }

    // MARK: - State

    private func registerHotKeys() {
        guard hotKeys.isEmpty else { return }
        let bindings: [(Shortcut, () -> Void)] = [
            (previousKey, { [weak self] in self?.step(-1) }),
            (nextKey, { [weak self] in self?.step(1) }),
            (widthKey, { [weak self] in self?.cycleWidth() }),
            (centerKey, { [weak self] in self?.center() }),
            (narrowerKey, { [weak self] in self?.nudgeWidth(-1) }),
            (widerKey, { [weak self] in self?.nudgeWidth(1) }),
        ]
        var refused: [String] = []
        for (shortcut, action) in bindings {
            if let id = HotKeys.shared.register(shortcut, action: action) {
                hotKeys.append(id)
            } else {
                refused.append(shortcut.label)
            }
        }
        if !refused.isEmpty {
            note = localized("Shortcut taken by another app: %@", refused.joined(separator: " "))
        }
        startScrollTap()
    }

    /// Sideways swipes with ⌃⌥ anywhere, or over a title bar in the strip.
    private func startScrollTap() {
        let tap = StripScrollTap.shared
        tap.frames = { [weak self] in
            guard let self else { return [] }
            return columns.filter { inView.contains($0.id) }.compactMap { applied[$0.id] }
        }
        tap.onScroll = { [weak self] event, starting in _ = self?.scrolled(event, starting: starting) }
        if !tap.start() {
            note = localized("Allow Accessibility to swipe the strip from anywhere")
        }
    }

    private func reset(keepNote: Bool = false, keepLeftOut: Bool = false) {
        for id in hotKeys { HotKeys.shared.unregister(id) }
        hotKeys = []
        StripScrollTap.shared.stop()
        StripResizeWatcher.shared.stop()
        mover.forget()
        swipe = nil
        columns = []
        windows = [:]
        original = [:]
        applied = [:]
        failures = [:]
        inView = []
        focus = 0
        offset = 0
        if !keepLeftOut { leftOut = [] }
        if !keepNote { note = nil }
    }

    /// The built-in display; the main one on a Mac without one or with the lid
    /// closed.
    private static var stripScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// The strip's Accessibility calls. Not main-actor: an app that is slow to
/// answer (Electron apps often are) would otherwise freeze the notch, so every
/// call runs on a background task with a short timeout.
enum StripAX {
    enum Probe { case frame(CGRect), minimized, fullScreen, hidden, unreachable }

    /// Seconds to wait for an app before giving up on a call.
    private static let timeout: Float = 0.6

    static func probe(_ window: AttachedWindow) -> Probe {
        guard let element = element(for: window) else { return .unreachable }
        if bool(element, kAXMinimizedAttribute) { return .minimized }
        if bool(element, "AXFullScreen") { return .fullScreen }
        guard let frame = frame(of: element) else { return .unreachable }
        return .frame(frame)
    }

    /// Moves and resizes, then returns where the window really ended up.
    /// Nil when the window could not be found or would not move.
    static func setFrame(_ rect: CGRect, of window: AttachedWindow) -> CGRect? {
        guard let element = element(for: window) else { return nil }
        var origin = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size)
        else { return nil }
        // Size, move, size again: a window that cannot be that big where it is
        // gets clamped, and the second size lets it reach the target.
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        guard moved == .success else { return nil }
        return frame(of: element) ?? rect
    }

    /// Brings the window to the front of its app; with `focus`, also makes it
    /// the app's focused window.
    static func frame(of window: AttachedWindow) -> CGRect? {
        element(for: window).flatMap(frame(of:))
    }

    /// Brings the window to the front of its app; with `focus`, also makes it
    /// the app's focused window.
    static func raise(_ element: AXUIElement, pid: pid_t, focus: Bool) {
        guard focus else {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            return
        }
        let app = application(pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var id: CGWindowID = 0
        return stripWindowID(value as! AXUIElement, &id) == .success ? id : nil
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func element(for window: AttachedWindow) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(window.pid), kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return nil }
        let match = elements.first { element in
            var id: CGWindowID = 0
            return stripWindowID(element, &id) == .success && id == window.id
        }
        if let match { AXUIElementSetMessagingTimeout(match, timeout) }
        return match
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let positionValue = value, AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        else { return nil }
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let sizeValue = value, AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// Notices a strip window's edge being dragged by hand, through Accessibility
/// notifications from the window's app, and reports it once the drag has
/// settled. The strip's own resizes are reported too; it tells them apart.
@MainActor
final class StripResizeWatcher {
    static let shared = StripResizeWatcher()

    var onResize: ((CGWindowID) -> Void)?
    private var observers: [AXObserver] = []
    private var pending: [CGWindowID: Task<Void, Never>] = [:]

    func watch(_ windows: [AttachedWindow]) {
        stop()
        for (pid, group) in Dictionary(grouping: windows, by: \.pid) {
            var created: AXObserver?
            let status = AXObserverCreate(pid, { _, element, _, _ in
                var id: CGWindowID = 0
                guard stripWindowID(element, &id) == .success else { return }
                // The observer's source is on the main run loop.
                MainActor.assumeIsolated { StripResizeWatcher.shared.changed(id) }
            }, &created)
            guard status == .success, let observer = created else { continue }
            for window in group {
                guard let element = StripAX.element(for: window) else { continue }
                AXObserverAddNotification(observer, element, kAXResizedNotification as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers.append(observer)
        }
    }

    func stop() {
        for observer in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers = []
        pending.values.forEach { $0.cancel() }
        pending = [:]
    }

    /// A drag sends a resize for every step; report only once it pauses.
    private func changed(_ id: CGWindowID) {
        pending[id]?.cancel()
        pending[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            pending[id] = nil
            onResize?(id)
        }
    }
}
