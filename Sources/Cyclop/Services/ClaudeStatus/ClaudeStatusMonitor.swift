import AppKit
import ApplicationServices
import Combine

/// One Claude window as the notch shows it.
struct ClaudeWindowStatus: Identifiable, Equatable {
    let id: CGWindowID
    var title: String
    var frame: CGRect
    var activity: ClaudeActivity
    /// The label that decided the last reading, for Settings.
    var matched: String?
    /// Threads waiting on you, as Claude counts them.
    var waiting: Int?

    var name: String { title.isEmpty ? "Claude" : title }

    /// "notch-app · Working · 6 waiting"
    var summary: String {
        var parts = [name, activity.label]
        if let waiting, activity != .unknown { parts.append(localized("%ld waiting", waiting)) }
        return parts.joined(separator: " · ")
    }
}

/// Watches the Claude desktop app's windows and keeps one status per window.
///
/// **It only reads.** The rules are the user's, and they are strict: nothing
/// here may interrupt, inject into or risk what Claude is doing. So the
/// monitor never clicks, presses, focuses, types or sends anything to Claude.
/// The single write is `AXManualAccessibility = true` on the app, the switch
/// Electron gives screen readers to expose the page; it is put back when the
/// monitor stops. A click on a dot is the user's own, and raises the window
/// the same way the Windows tab does.
///
/// It reads every 2.5 s, sooner when Claude reports a change (it rarely does
/// while unlocked, so the poll is what counts), never more than once a
/// second, and never while the Mac is locked or the display asleep: locking
/// tears Claude's tree down, and the states on screen wait for the unlock.
/// A read is a search for buttons, a few milliseconds a window.
@MainActor
final class ClaudeStatusMonitor: ObservableObject {
    enum Problem: Equatable {
        case noAccess
        case notRunning
        case paused
    }

    /// Every Claude window found, in a stable order: by name.
    @Published private(set) var windows: [ClaudeWindowStatus] = []
    /// A window that just started waiting on you; the notch drops its name
    /// for a moment.
    @Published private(set) var banner: CGWindowID?
    /// The dot under the pointer.
    @Published var hovered: CGWindowID?
    @Published private(set) var problem: Problem?
    @Published private(set) var rulesBroken = false
    @Published private(set) var lastRead: Date?
    @Published private(set) var lastReadDuration: TimeInterval = 0

    /// Whether a window that starts waiting on you drops its name under the
    /// notch for a moment.
    @Published var bannersEnabled: Bool {
        didSet { UserDefaults.standard.set(bannersEnabled, forKey: Self.bannersKey) }
    }

    private static let bannersKey = "claudeStatus.banners"
    static let bannerDuration: TimeInterval = 2.5
    /// Closest two reads may start, however busy Claude's events are.
    static let minInterval: TimeInterval = 1
    static let fallbackInterval: TimeInterval = 2.5

    private let reader = ClaudeAXReader()
    private var rules = ClaudeStatusRules.defaults.compiled()
    private var trackers: [CGWindowID: ClaudeActivityTracker] = [:]
    private var pid: pid_t?
    /// The Claude process whose Accessibility switch this monitor turned on,
    /// so stopping only ever undoes its own change.
    private var switchedOn: pid_t?
    private var observer: AXObserver?
    private var fallback: Timer?
    private var scheduled: DispatchWorkItem?
    private var scheduledAt: Date?
    private var bannerWork: DispatchWorkItem?
    private var lastReadStart = Date.distantPast
    private var running = false
    private var asleep = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        bannersEnabled = UserDefaults.standard.object(forKey: Self.bannersKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        reloadRules()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { monitor, app in
            if app?.bundleIdentifier == WindowStore.claudeBundleID { monitor.attach() }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { monitor, app in
            if app?.processIdentifier == monitor.pid { monitor.detach(restore: false) }
        }
        // Coming back to a finished window is what clears it.
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { monitor, app in
            if app?.processIdentifier == monitor.pid { monitor.requestRead(after: 0.3) }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { monitor, _ in monitor.asleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { monitor, _ in
            monitor.asleep = false
            monitor.requestRead(after: 1)
        }
        let distributed = DistributedNotificationCenter.default()
        // Locking tears Claude's tree down; every element held from before
        // is dead, so they are all looked up afresh.
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { monitor, _ in
            monitor.reader.forget()
            monitor.requestRead(after: 1)
        }

        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        fallback = timer

        attach()
    }

    func stop() {
        guard running else { return }
        running = false
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        fallback?.invalidate()
        fallback = nil
        detach(restore: true)
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ body: @escaping @MainActor (ClaudeStatusMonitor, NSRunningApplication?) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self, app)
            }
        }
        tokens.append((center, token))
    }

    /// Finds Claude, exposes its pages and listens for its changes.
    private func attach() {
        guard running else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: WindowStore.claudeBundleID)
            .first(where: { !$0.isTerminated })
        else {
            detach(restore: false)
            problem = .notRunning
            return
        }
        guard WindowFocus.hasAccess else {
            problem = .noAccess
            return
        }
        let newPID = app.processIdentifier
        if pid != newPID {
            detach(restore: true)
            pid = newPID
        }
        exposePages(of: newPID)
        listen(to: newPID)
        problem = nil
        requestRead(after: 0.5)
    }

    /// Lets go of Claude. `restore` puts the Accessibility switch back if this
    /// monitor turned it on and Claude is still running.
    private func detach(restore: Bool) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        if restore, let switchedOn, let pid, switchedOn == pid {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, ClaudeAXReader.timeout)
            AXUIElementSetAttributeValue(app, Self.manualAccessibility, kCFBooleanFalse)
        }
        switchedOn = nil
        pid = nil
        scheduled?.cancel()
        scheduled = nil
        scheduledAt = nil
        trackers.removeAll()
        windows = []
        banner = nil
        reader.forget()
    }

    private static let manualAccessibility = "AXManualAccessibility" as CFString

    /// Electron keeps its pages out of Accessibility until an assistive app
    /// asks for them. This is that ask, and the only write to Claude.
    private func exposePages(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ClaudeAXReader.timeout)
        var current: CFTypeRef?
        AXUIElementCopyAttributeValue(app, Self.manualAccessibility, &current)
        if (current as? Bool) == true { return }
        if AXUIElementSetAttributeValue(app, Self.manualAccessibility, kCFBooleanTrue) == .success {
            switchedOn = pid
        }
    }

    private func listen(to pid: pid_t) {
        guard observer == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<ClaudeStatusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.claudeChanged() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ClaudeAXReader.timeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            "AXLiveRegionChanged", "AXLiveRegionCreated", "AXElementBusyChanged",
            kAXTitleChangedNotification, kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        ] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    // MARK: - Reading

    fileprivate func claudeChanged() {
        requestRead(after: 0.4)
    }

    private func tick() {
        if pid == nil || problem == .noAccess || problem == .notRunning { attach() }
        requestRead(after: 0)
    }

    private var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Asks for a read `delay` seconds from now, folded into one already
    /// waiting, and never sooner than `minInterval` after the last one.
    private func requestRead(after delay: TimeInterval) {
        guard running, pid != nil else { return }
        let earliest = lastReadStart.addingTimeInterval(Self.minInterval)
        let at = max(Date().addingTimeInterval(delay), earliest)
        if let scheduledAt, scheduledAt <= at { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = nil
                self?.scheduledAt = nil
                self?.readNow()
            }
        }
        scheduled = work
        scheduledAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    private func readNow() {
        guard running, let pid else { return }
        guard WindowFocus.hasAccess else {
            problem = .noAccess
            return
        }
        // Claude hides its pages while locked: reading would only turn every
        // dot grey. The states on screen are kept until it unlocks.
        if asleep || isScreenLocked {
            problem = .paused
            return
        }
        if problem == .paused { problem = nil }
        lastReadStart = Date()
        reader.read(pid: pid, rules: rules) { [weak self] result in
            MainActor.assumeIsolated { self?.apply(result) }
        }
    }

    private func apply(_ result: ClaudeReadResult) {
        guard running, result.pid == pid else { return }
        let now = Date()
        lastRead = now
        lastReadDuration = result.duration
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

        var next: [ClaudeWindowStatus] = []
        var waiting: CGWindowID?
        for window in result.windows {
            var tracker = trackers[window.id] ?? ClaudeActivityTracker()
            let before = tracker.shown
            let seenBefore = tracker.shownSince != nil
            let focused = frontmost && result.focusedWindow == window.id
            tracker.update(window.reading, focused: focused, now: now)
            trackers[window.id] = tracker
            if tracker.shown == .needsInput, before != .needsInput, seenBefore, !focused {
                waiting = window.id
            }
            next.append(ClaudeWindowStatus(
                id: window.id, title: window.title, frame: window.frame,
                activity: tracker.shown, matched: window.matched, waiting: tracker.waiting
            ))
        }
        let present = Set(next.map(\.id))
        trackers = trackers.filter { present.contains($0.key) }
        next.sort { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        if next != windows { windows = next }
        if let waiting, bannersEnabled { showBanner(waiting) }
        if let hovered, !present.contains(hovered) { self.hovered = nil }

        // A state waiting out its hold gets a read at the end of it, so it
        // does not have to wait for Claude's next event.
        if let deadline = trackers.values.compactMap(\.pendingDeadline).min() {
            requestRead(after: max(0, deadline.timeIntervalSinceNow) + 0.1)
        }
    }

    private func showBanner(_ id: CGWindowID) {
        bannerWork?.cancel()
        banner = id
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.banner = nil }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerDuration, execute: work)
    }

    // MARK: - Acting (the user's click only)

    /// Raises the window, switching desktops if it is on another one. The
    /// same jump the Windows tab makes; nothing inside the page is touched.
    func jump(to id: CGWindowID) {
        guard let pid, let window = windows.first(where: { $0.id == id }) else { return }
        bannerWork?.cancel()
        banner = nil
        WindowFocus.raise(AttachedWindow(
            id: id, pid: pid, bundleID: WindowStore.claudeBundleID, appName: "Claude",
            title: window.title, frame: window.frame, isOnScreen: true
        ))
        requestRead(after: 0.8)
    }

    func requestAccess() {
        WindowFocus.requestAccess()
    }

    /// Re-reads the rules file, for Settings after a hand edit.
    func reloadRules() {
        let loaded = ClaudeStatusRules.load()
        rules = loaded.rules.compiled()
        rulesBroken = loaded.broken
        requestRead(after: 0)
    }

    // MARK: - For the notch

    /// Whether the folded notch has anything to show: some window is working,
    /// waiting or done, or a name is being shown.
    var hasNews: Bool {
        windows.contains { $0.activity.isNotable } || banner != nil
    }

    /// The line under the notch: the window that just started waiting, or
    /// the dot under the pointer.
    var caption: String? {
        if let banner, let window = windows.first(where: { $0.id == banner }) {
            return localized("%@ needs you", window.name)
        }
        if let hovered, let window = windows.first(where: { $0.id == hovered }) {
            return window.summary
        }
        return nil
    }
}
