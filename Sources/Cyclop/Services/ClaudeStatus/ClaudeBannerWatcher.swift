import AppKit
import ApplicationServices

/// One Claude notification as its banner showed it.
struct ClaudeBanner: Equatable, Sendable {
    /// Notification Center's own id for the notification.
    let id: String
    /// The project or window it is about: "Sift app".
    let title: String
    /// The message, without Claude's "Claude: " prefix.
    let body: String
    let seen: Date
}

/// Reads Claude's notification banners off the screen, through
/// Accessibility, the moment Notification Center shows them.
///
/// **Read-only.** It reads the banner's texts and nothing else: it never
/// presses, closes or hovers a banner, and Notification Center's own
/// settings and history are never touched. No Full Disk Access: only what
/// macOS draws on screen is read, so a banner a Focus mode holds back is not
/// seen (the dots still are, they read Claude's windows).
///
/// Measured on macOS 27.0.1: a banner is an `AXGroup` with the subrole
/// `AXNotificationCenterAlert`, a description "Claude, <title>, <body>", an
/// identifier unique to the notification, and two texts with the
/// identifiers "title" and "body". Notification Center reports
/// `AXLayoutChanged` when one appears, so the read follows that event, with
/// a slow poll in case an event is missed.
@MainActor
final class ClaudeBannerWatcher {
    static let notificationCenterID = "com.apple.notificationcenterui"
    nonisolated static let appName = "Claude"

    var onBanner: ((ClaudeBanner) -> Void)?

    private let queue = DispatchQueue(label: "cyclop.claude-banners", qos: .utility)
    private var pid: pid_t?
    private var observer: AXObserver?
    private var poll: Timer?
    private var pending = false
    /// Ids already handed on, so a banner is reported once however many
    /// times its layout changes. Capped: ids are never reused.
    private var reported: [String] = []

    func start() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        tick()
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        unlisten()
    }

    private func tick() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID)
            .first { !$0.isTerminated }
        guard let running, WindowFocus.hasAccess else {
            unlisten()
            return
        }
        if running.processIdentifier != pid {
            unlisten()
            pid = running.processIdentifier
            listen(to: running.processIdentifier)
        }
        read()
    }

    private func listen(to pid: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<ClaudeBannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.read() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in ["AXLayoutChanged", kAXWindowCreatedNotification, kAXCreatedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func unlisten() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        pid = nil
    }

    /// One read at a time, off the main thread; a layout change during a
    /// read is picked up by the read after it.
    private func read() {
        guard let pid, !pending else { return }
        pending = true
        let known = Set(reported)
        queue.async {
            let found = Self.banners(of: pid).filter { !known.contains($0.id) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending = false
                    for banner in found where !self.reported.contains(banner.id) {
                        self.reported.append(banner.id)
                        self.onBanner?(banner)
                    }
                    if self.reported.count > 200 { self.reported.removeFirst(self.reported.count - 200) }
                }
            }
        }
    }

    // MARK: - Off the main thread

    private nonisolated static let maxDepth = 8
    private nonisolated static let maxNodes = 400

    /// Claude's banners on screen now.
    private nonisolated static func banners(of pid: pid_t) -> [ClaudeBanner] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var found: [ClaudeBanner] = []
        var level = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var visited = 0
        for _ in 0..<maxDepth where !level.isEmpty && visited < maxNodes {
            var next: [AXUIElement] = []
            for element in level {
                visited += 1
                AXUIElementSetMessagingTimeout(element, 0.25)
                if (value(element, kAXSubroleAttribute) as? String) == "AXNotificationCenterAlert" {
                    if let banner = banner(element) { found.append(banner) }
                    continue
                }
                next += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            level = next
        }
        return found
    }

    private nonisolated static func banner(_ alert: AXUIElement) -> ClaudeBanner? {
        let description = value(alert, kAXDescriptionAttribute) as? String ?? ""
        guard let parsed = parse(description: description),
              let id = value(alert, kAXIdentifierAttribute) as? String, !id.isEmpty
        else { return nil }
        // The texts themselves, when they are there: the description joins
        // them with commas, and a title may hold one.
        var title = parsed.title
        var body = parsed.body
        for child in (value(alert, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            AXUIElementSetMessagingTimeout(child, 0.25)
            guard let text = value(child, kAXValueAttribute) as? String else { continue }
            switch value(child, kAXIdentifierAttribute) as? String {
            case "title": title = text
            case "body": body = text
            default: break
            }
        }
        return ClaudeBanner(id: id, title: title, body: clean(body), seen: Date())
    }

    /// "Claude, Sift app, Claude: The merges are underway…" → title and
    /// body, or nil when the banner is not Claude's.
    nonisolated static func parse(description: String) -> (title: String, body: String)? {
        let prefix = appName + ", "
        guard description.hasPrefix(prefix) else { return nil }
        let rest = description.dropFirst(prefix.count)
        guard let comma = rest.range(of: ", ") else { return (String(rest), "") }
        return (String(rest[..<comma.lowerBound]), String(rest[comma.upperBound...]))
    }

    /// Drops Claude's "Claude: " in front of every message.
    nonisolated static func clean(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = appName + ": "
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    private nonisolated static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
}
