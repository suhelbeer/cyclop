import AppKit
@preconcurrency import ScreenCaptureKit

/// A window shown in the Windows tab.
struct AttachedWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    /// False when minimized, hidden with ⌘H, or on a desktop macOS stopped
    /// drawing. Capture then returns nothing new, so the last image is kept.
    let isOnScreen: Bool

    var label: String { title.isEmpty ? appName : title }
}

/// Which windows are attached, their live previews, and jumping to them.
///
/// Everything here is local. Frames come from ScreenCaptureKit straight into
/// this process and are only ever drawn in the panel; nothing is written to
/// disk or sent anywhere.
///
/// Capture runs only while the panel is open on this tab: a small frame of
/// every attached window about once a second, and a large one of the window
/// under the pointer a few times a second. With the panel closed it costs
/// nothing.
@MainActor
final class WindowStore: ObservableObject {
    @Published private(set) var attached: [AttachedWindow] = []
    /// Every capturable window, for the attach list.
    @Published private(set) var candidates: [AttachedWindow] = []
    @Published private(set) var thumbnails: [CGWindowID: CGImage] = [:]
    /// Windows whose last capture returned nothing (minimized, app hidden,
    /// permission gone), so the frame on screen is old. Off-screen is not the
    /// same thing: windows on other desktops are captured and stay live.
    @Published private(set) var stale: Set<CGWindowID> = []
    @Published private(set) var largePreview: (id: CGWindowID, image: CGImage)?
    @Published private(set) var hasScreenAccess = CGPreflightScreenCaptureAccess()
    @Published var hovered: CGWindowID? {
        didSet { if hovered != oldValue { refreshLarge() } }
    }
    /// The app that was in front before the last jump, for "Back".
    @Published private(set) var returnApp: NSRunningApplication?

    /// The Claude desktop app. Its windows are attached unless switched off.
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    private let appsKey = "windows.attachedApps"
    private let windowsKey = "windows.attachedWindows"
    private let detachedKey = "windows.detachedWindows"

    /// Apps whose every window is attached.
    private(set) var attachedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: appsKey) ?? [Self.claudeBundleID]) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: appsKey) }
    }
    /// Single windows attached on their own. Window ids last until the app
    /// quits, which is as long as a pick here needs to hold.
    private var attachedWindowIDs: Set<CGWindowID> {
        get { Set((UserDefaults.standard.array(forKey: windowsKey) as? [Int] ?? []).map(CGWindowID.init)) }
        set { UserDefaults.standard.set(newValue.map(Int.init).sorted(), forKey: windowsKey) }
    }
    /// Windows taken out of an attached app.
    private var detachedWindowIDs: Set<CGWindowID> {
        get { Set((UserDefaults.standard.array(forKey: detachedKey) as? [Int] ?? []).map(CGWindowID.init)) }
        set { UserDefaults.standard.set(newValue.map(Int.init).sorted(), forKey: detachedKey) }
    }

    private var scWindows: [CGWindowID: SCWindow] = [:]
    /// Closed windows their app keeps listed (see `UndrawnWindows`).
    private var undrawn = UndrawnWindows()
    private var thumbTimer: Timer?
    private var largeTimer: Timer?
    private var refreshing = false
    private var lastListRefresh = Date.distantPast
    private var capturingLarge = false

    /// Measured on a 1440×827 window: a capture takes ~25–35 ms, so the large
    /// preview can run at about 15 frames a second and the strip at 2.
    static let thumbInterval: TimeInterval = 0.5
    static let largeInterval: TimeInterval = 0.06
    /// The window list is heavier than a frame and changes slowly.
    static let listInterval: TimeInterval = 2
    /// Longest edge, in pixels, of each kind of frame.
    static let thumbSize: CGFloat = 360
    static let largeSize: CGFloat = 1100

    // MARK: - Lifecycle

    var panelActive = false {
        didSet { if panelActive != oldValue { setActive(panelActive && paneVisible) } }
    }
    var paneVisible = false {
        didSet { if paneVisible != oldValue { setActive(panelActive && paneVisible) } }
    }

    private func setActive(_ active: Bool) {
        thumbTimer?.invalidate()
        thumbTimer = nil
        largeTimer?.invalidate()
        largeTimer = nil
        guard active else {
            hovered = nil
            largePreview = nil
            return
        }
        hasScreenAccess = CGPreflightScreenCaptureAccess()
        guard hasScreenAccess else { return }
        tick()
        let thumbs = Timer(timeInterval: Self.thumbInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let large = Timer(timeInterval: Self.largeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLarge() }
        }
        RunLoop.main.add(thumbs, forMode: .common)
        RunLoop.main.add(large, forMode: .common)
        thumbTimer = thumbs
        largeTimer = large
    }

    func requestScreenAccess() {
        // Shows the system prompt once; after that macOS only points to
        // System Settings, and the app must be relaunched to see the grant.
        hasScreenAccess = CGRequestScreenCaptureAccess()
        if !hasScreenAccess {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: - Attaching

    func isAttached(_ window: AttachedWindow) -> Bool {
        if attachedWindowIDs.contains(window.id) { return true }
        return attachedApps.contains(window.bundleID) && !detachedWindowIDs.contains(window.id)
    }

    func toggle(_ window: AttachedWindow) {
        if isAttached(window) {
            attachedWindowIDs.remove(window.id)
            if attachedApps.contains(window.bundleID) { detachedWindowIDs.insert(window.id) }
        } else {
            detachedWindowIDs.remove(window.id)
            if !attachedApps.contains(window.bundleID) { attachedWindowIDs.insert(window.id) }
        }
        apply()
    }

    func isAppAttached(_ bundleID: String) -> Bool { attachedApps.contains(bundleID) }

    func toggleApp(_ bundleID: String) {
        var apps = attachedApps
        if apps.contains(bundleID) { apps.remove(bundleID) } else { apps.insert(bundleID) }
        attachedApps = apps
        let ids = Set(candidates.filter { $0.bundleID == bundleID }.map(\.id))
        detachedWindowIDs.subtract(ids)
        attachedWindowIDs.subtract(ids)
        apply()
    }

    // MARK: - Fill screen

    /// Sizes before "Fill screen", by window, in Accessibility coordinates.
    private var savedFrames: [CGWindowID: CGRect] = [:]
    /// True between "Fill screen" and "Restore".
    @Published private(set) var isFilled = false
    /// What the last fill could not do, for the pane to say.
    @Published private(set) var fillNote: String?
    private var filling = false

    /// One click: every attached window takes the visible area of the screen
    /// it is on, stacked, so whichever the notch brings forward is full size.
    /// Not macOS full screen: that would give each window its own desktop.
    /// A second click puts every window back where it was.
    func toggleFill() {
        guard WindowFocus.hasAccess else {
            WindowFocus.requestAccess()
            fillNote = localized("Allow Accessibility to resize windows")
            return
        }
        isFilled ? restoreFrames() : fillScreen()
    }

    private func fillScreen() {
        guard !filling else { return }
        filling = true
        Task { @MainActor in
            defer { filling = false }
            let windows = attached
            var saved: [CGWindowID: CGRect] = [:]
            var missed = fill(windows, saving: &saved)
            // Accessibility cannot see a window on another desktop, so those
            // are missed. Go to them the way a click on their preview does
            // (that also arms "Back"), give macOS a moment to switch, and try
            // once more.
            if let first = missed.first {
                jump(to: first)
                try? await Task.sleep(for: .milliseconds(900))
                missed = fill(missed, saving: &saved)
            }
            savedFrames = saved
            isFilled = !saved.isEmpty
            fillNote = missed.isEmpty
                ? nil
                : localized("%d of %d windows resized; the rest could not be reached", saved.count, windows.count)
        }
    }

    /// Resizes what Accessibility can reach; returns the windows it could not.
    private func fill(_ windows: [AttachedWindow], saving saved: inout [CGWindowID: CGRect]) -> [AttachedWindow] {
        let screens = NSScreen.screens.map { WindowLayout.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return windows }
        var missed: [AttachedWindow] = []
        for window in windows {
            guard let current = WindowFocus.frame(of: window),
                  let target = WindowLayout.fillFrame(for: current, in: screens, primaryHeight: primaryHeight),
                  WindowFocus.setFrame(target, of: window)
            else {
                missed.append(window)
                continue
            }
            saved[window.id] = current
        }
        return missed
    }

    private func restoreFrames() {
        for window in attached {
            if let frame = savedFrames[window.id] { WindowFocus.setFrame(frame, of: window) }
        }
        savedFrames = [:]
        isFilled = false
        fillNote = nil
    }

    // MARK: - Jumping

    /// Arrange ⇄ Release for the strip.
    func toggleStrip() {
        let strip = WindowStrip.shared
        strip.isArranged ? strip.release() : strip.arrange(attached, joining: attachedApps)
    }

    /// A click on a preview: inside an arranged strip it scrolls there,
    /// otherwise it jumps to the window as before.
    func open(_ window: AttachedWindow) {
        let strip = WindowStrip.shared
        if strip.index(of: window.id) != nil {
            strip.focus(on: window.id)
        } else {
            jump(to: window)
        }
    }

    /// Brings the window forward and makes its app active. If a full-screen
    /// app was in front, macOS slides to the window's desktop: no app can put
    /// another app's window over a full-screen space.
    func jump(to window: AttachedWindow) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != window.pid, front != NSRunningApplication.current {
            returnApp = front
        }
        WindowFocus.raise(window)
    }

    /// Back to the app that was in front before the last jump.
    func goBack() {
        guard let app = returnApp else { return }
        returnApp = nil
        WindowFocus.activate(app)
    }

    /// The app "Back" would return to, while it is still worth offering:
    /// it is running and is not already in front.
    var backTarget: NSRunningApplication? {
        guard let app = returnApp, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication != app
        else { return nil }
        return app
    }

    // MARK: - Capture

    private func tick() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            if Date().timeIntervalSince(lastListRefresh) >= Self.listInterval || attached.isEmpty {
                lastListRefresh = Date()
                await refreshWindows()
            }
            // Windows on another desktop are captured too: ScreenCaptureKit
            // cannot see them, `capture` falls back to `OffSpaceCapture`.
            // Anything that still returns nothing keeps its last frame.
            for window in attached {
                if let image = await capture(window.id, size: Self.thumbSize) {
                    thumbnails[window.id] = image
                    stale.remove(window.id)
                } else {
                    stale.insert(window.id)
                }
            }
        }
    }

    private func refreshLarge() {
        guard let id = hovered else {
            largePreview = nil
            return
        }
        guard !capturingLarge else { return }
        capturingLarge = true
        Task { @MainActor in
            defer { capturingLarge = false }
            let image = await capture(id, size: Self.largeSize)
            guard hovered == id else { return }
            guard let image else {
                stale.insert(id)
                return
            }
            stale.remove(id)
            largePreview = (id, image)
        }
    }

    private func refreshWindows() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var found: [CGWindowID: SCWindow] = [:]
        var list: [AttachedWindow] = []
        for window in content.windows {
            guard window.windowLayer == 0,
                  let app = window.owningApplication,
                  app.processID != own,
                  window.frame.width >= 160, window.frame.height >= 120
            else { continue }
            found[window.windowID] = window
            list.append(AttachedWindow(
                id: window.windowID,
                pid: app.processID,
                bundleID: app.bundleIdentifier,
                appName: app.applicationName,
                title: window.title ?? "",
                frame: window.frame,
                isOnScreen: window.isOnScreen
            ))
        }
        // A closed window its app keeps listed sits off screen like a window
        // on another desktop, but never draws: left in, its preview loads
        // forever. Checked for attached windows only, the ones shown.
        let now = Date()
        let offScreen = Set(list.filter { !$0.isOnScreen && isAttached($0) }.map(\.id))
        let due = undrawn.due(offScreen: offScreen, now: now)
        if !due.isEmpty {
            let results = await Task.detached(priority: .utility) {
                due.map { ($0, UndrawnWindows.draws($0)) }
            }.value
            for (id, draws) in results { undrawn.record(id, draws: draws, now: now) }
        }
        list.removeAll { undrawn.hidden.contains($0.id) }
        for id in undrawn.hidden { found[id] = nil }
        scWindows = found
        // Stable order: by app, then left to right, top to bottom, so a 2×2
        // grid on screen reads the same way in the tab.
        list.sort {
            ($0.appName, $0.frame.minY, $0.frame.minX) < ($1.appName, $1.frame.minY, $1.frame.minX)
        }
        if list != candidates { candidates = list }
        apply()
    }

    private func apply() {
        var now = candidates.filter(isAttached)
        // While the strip is arranged the tab follows its order: sorting by
        // position would shuffle the windows parked at the screen edges.
        let strip = WindowStrip.shared
        if strip.isArranged {
            let order = Dictionary(uniqueKeysWithValues: now.enumerated().map { ($1.id, $0) })
            now.sort {
                let a = strip.index(of: $0.id) ?? Int.max, b = strip.index(of: $1.id) ?? Int.max
                return a != b ? a < b : order[$0.id, default: 0] < order[$1.id, default: 0]
            }
            if !candidates.isEmpty { strip.windowsChanged(now) }
        }
        if now != attached { attached = now }
        let live = Set(candidates.map(\.id))
        // Forget picks for windows that no longer exist, so ids do not pile
        // up across relaunches of the attached apps.
        if !candidates.isEmpty {
            attachedWindowIDs.formIntersection(live)
            detachedWindowIDs.formIntersection(live)
        }
        thumbnails = thumbnails.filter { live.contains($0.key) }
        stale.formIntersection(live)
    }

    private func capture(_ id: CGWindowID, size: CGFloat) async -> CGImage? {
        guard let window = scWindows[id] else { return nil }
        // ScreenCaptureKit fails (-3811) for a window on a Space that is not
        // on screen — e.g. Safari full screen in front of tiled Claude windows.
        guard window.isOnScreen else { return await offSpaceFrame(id, size: size) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = size / max(window.frame.width, window.frame.height, 1)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            return image
        }
        return await offSpaceFrame(id, size: size)
    }

    private func offSpaceFrame(_ id: CGWindowID, size: CGFloat) async -> CGImage? {
        await Task.detached(priority: .utility) {
            SendableImage(image: OffSpaceCapture.image(of: id, maxEdge: size))
        }.value.image
    }
}
