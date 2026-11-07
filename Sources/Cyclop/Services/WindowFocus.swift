import AppKit
import ApplicationServices

/// Maps an Accessibility window to its CGWindowID. Private, but stable since
/// 10.x and used by every window manager on the Mac (AltTab, Rectangle,
/// yabai): there is no public way to go from a capture or CGWindowList id to
/// the window Accessibility can move or raise.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Switching to a specific window's own desktop, and making it the key window.
///
/// Measured on macOS 27 from a full-screen Safari desktop: this call alone
/// reports success and makes the app frontmost, but the screen stays where it
/// was. The desktop switch only happens once the window itself is raised
/// through Accessibility afterwards, which is why `raise` finds the window
/// even when it is on another desktop. It is private, and it is what AltTab
/// and similar switchers use; it is looked up at runtime, so if it ever
/// disappears `focus` returns false and the caller falls back to activation.
@MainActor
private enum SkyLight {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFront? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEvent: PostEvent? = symbol("SLPSPostEventRecordTo")
    /// Opened by path: a lookup in the default namespace only finds it while
    /// something else happens to have loaded ApplicationServices.
    private static let getPSN: GetPSN? = {
        let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        guard let services, let sym = dlsym(services, "GetProcessForPID") else { return nil }
        return unsafeBitCast(sym, to: GetPSN.self)
    }()

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// `kCPSUserGenerated`: treated like a click on the window, which is what
    /// makes macOS switch to its desktop.
    private static let userGenerated: UInt32 = 0x200

    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let postEvent, let getPSN else { return false }
        var psn = [UInt32](repeating: 0, count: 2)
        let ok = psn.withUnsafeMutableBytes { raw -> Bool in
            guard getPSN(pid, raw.baseAddress!) == 0 else { return false }
            guard setFront(raw.baseAddress!, windowID, userGenerated) == 0 else { return false }
            // Make it the key window: a synthetic mouse-down / mouse-up record
            // addressed to that window id.
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            var id = windowID
            memcpy(&bytes[0x3c], &id, MemoryLayout<UInt32>.size)
            memset(&bytes[0x20], 0xff, 0x10)
            for type: UInt8 in [0x01, 0x02] {
                bytes[0x08] = type
                _ = bytes.withUnsafeMutableBytes { postEvent(raw.baseAddress!, $0.baseAddress!) }
            }
            return true
        }
        return ok
    }
}

/// Raising a specific window of another app, and making an app active.
///
/// Needs Accessibility, which Cyclop already asks for the keyboard lock.
/// Without it the app is still activated, but macOS picks which of its
/// windows comes forward.
@MainActor
enum WindowFocus {
    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Brings one specific window to the front, over its siblings, switching
    /// to its desktop first when it is on another one.
    ///
    /// The window's Accessibility element is found first, even on another
    /// desktop. Then SkyLight makes it the app's front window and Accessibility
    /// raises it: that raise is what makes macOS switch desktops. Without the
    /// element (Accessibility off, or an app that does not expose it), the app
    /// is activated instead, which goes to the desktop the app was last used
    /// on. Either way the raise is retried while the switch animates, because
    /// activating can put the app's previous front window back on top.
    static func raise(_ window: AttachedWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        let element = hasAccess ? axWindow(for: window) : nil
        if element == nil || !SkyLight.focus(windowID: window.id, pid: window.pid) { activate(app) }
        if let element { raise(element, of: window.pid) }
        Task { @MainActor in
            var raised = 0
            for delay in [200, 300, 400, 500, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                if raiseWindow(window) { raised += 1 }
                // Twice found: once is not enough, the second one is after the
                // desktop switch and the activation have both landed.
                if raised >= 2 { return }
            }
        }
    }

    /// Un-minimizes, makes it the app's main and focused window, and raises
    /// it. False when Accessibility cannot find the window.
    @discardableResult
    private static func raiseWindow(_ window: AttachedWindow) -> Bool {
        guard hasAccess, let element = axWindow(for: window) else { return false }
        raise(element, of: window.pid)
        return true
    }

    private static func raise(_ element: AXUIElement, of pid: pid_t) {
        // Un-minimize first: raising a minimized window does nothing.
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Since macOS 14 a plain `activate()` from an app that is not in front
    /// (Cyclop never is) can be ignored. Setting the app frontmost through
    /// Accessibility is honoured; `openApplication` is the fallback without it.
    static func activate(_ app: NSRunningApplication) {
        if hasAccess {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
                return
            }
        }
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The window's frame as Accessibility sees it (origin top-left of the
    /// primary display). Nil without access, or for a window Accessibility
    /// cannot find — typically one on another desktop.
    static func frame(of window: AttachedWindow) -> CGRect? {
        guard hasAccess, let element = axWindow(for: window) else { return nil }
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

    /// Moves and resizes a window. Size first and again after the move: a
    /// window that cannot be that big at its old position is clamped, and
    /// setting the size once more at the new origin lets it reach the target.
    @discardableResult
    static func setFrame(_ rect: CGRect, of window: AttachedWindow) -> Bool {
        guard hasAccess, let element = axWindow(for: window) else { return false }
        var origin = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size)
        else { return false }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        return moved == .success
    }

    /// Elements found by `searchWindow`, so the search runs once per window.
    private static var found: [CGWindowID: AXUIElement] = [:]

    private static func axWindow(for window: AttachedWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
            ? (value as? [AXUIElement] ?? [])
            : []
        for element in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id == window.id { return element }
        }
        // Not in the list: on another desktop. Ask for it directly.
        if let element = cachedOrSearched(window) { return element }
        // Fallback when the private calls are unavailable: same title.
        return windows.first { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return (title as? String) == window.title && !window.title.isEmpty
        }
    }

    private static func cachedOrSearched(_ window: AttachedWindow) -> AXUIElement? {
        if let element = found[window.id] {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id == window.id { return element }
            found[window.id] = nil
        }
        guard let element = searchWindow(window) else { return nil }
        found[window.id] = element
        return element
    }

    /// The window's element on another desktop, by trying element ids.
    private static func searchWindow(_ window: AttachedWindow) -> AXUIElement? {
        WindowLiveness.search(pid: window.pid, for: [window.id]).windows[window.id]
    }

    // MARK: - Ghosts

    /// Windows found to be ghosts: a record the window server kept after the
    /// window closed (see `WindowLiveness`). A closed window does not come
    /// back, so the verdict stands until the record is gone.
    private static var ghosts: Set<CGWindowID> = []
    /// When each window was last searched for without an answer, so an app
    /// that never answers is not searched on every list refresh.
    private static var lastSearch: [CGWindowID: Date] = [:]
    private static let searchInterval: TimeInterval = 15

    /// Whether the window is a leftover of a closed window rather than a
    /// window. Only ever true for a window that is not on screen, and only
    /// when Accessibility says so: when it cannot tell, the window is kept.
    /// Reads only.
    static func isGhost(_ window: AttachedWindow) -> Bool {
        guard !window.isOnScreen, hasAccess else { return false }
        if ghosts.contains(window.id) { return true }
        if let element = found[window.id] {
            switch WindowLiveness.verdict(of: element) {
            case .real, .unknown: return false
            case .ghost: found[window.id] = nil
            }
        } else if inAppList(window) {
            return false
        }
        if let last = lastSearch[window.id], Date().timeIntervalSince(last) < searchInterval { return false }
        lastSearch[window.id] = Date()
        let result = WindowLiveness.search(pid: window.pid, for: [window.id])
        if let element = result.windows[window.id] {
            found[window.id] = element
            lastSearch[window.id] = nil
            return false
        }
        guard result.ghosts.contains(window.id) else { return false }
        ghosts.insert(window.id)
        return true
    }

    /// Drops what is known about windows that are gone from the window list.
    static func forget(allBut live: Set<CGWindowID>) {
        ghosts.formIntersection(live)
        lastSearch = lastSearch.filter { live.contains($0.key) }
        found = found.filter { live.contains($0.key) }
    }

    private static func inAppList(_ window: AttachedWindow) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return false }
        return (value as? [AXUIElement] ?? []).contains { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == window.id
        }
    }
}
