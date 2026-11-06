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
    private var thumbTimer: Timer?
    private var largeTimer: Timer?
    private var refreshing = false
    private var capturingLarge = false

    static let thumbInterval: TimeInterval = 1
    static let largeInterval: TimeInterval = 0.25
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

    // MARK: - Jumping

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
            await refreshWindows()
            // Windows on another desktop are captured too: ScreenCaptureKit
            // cannot see them, `capture` falls back to `OffSpaceCapture`.
            // Anything that still returns nothing keeps its last frame.
            for window in attached {
                if let image = await capture(window.id, size: Self.thumbSize) {
                    thumbnails[window.id] = image
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
            guard let image = await capture(id, size: Self.largeSize), hovered == id else { return }
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
        let now = candidates.filter(isAttached)
        if now != attached { attached = now }
        let live = Set(candidates.map(\.id))
        // Forget picks for windows that no longer exist, so ids do not pile
        // up across relaunches of the attached apps.
        if !candidates.isEmpty {
            attachedWindowIDs.formIntersection(live)
            detachedWindowIDs.formIntersection(live)
        }
        thumbnails = thumbnails.filter { live.contains($0.key) }
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
