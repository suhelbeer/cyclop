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
/// Activating an app only takes macOS to the desktop the app was last used on,
/// not to the one holding the window that was asked for: with Claude windows
/// tiled on one desktop and a full-screen one on another, the wrong desktop
/// came up and Accessibility could not see the window to raise it. SkyLight's
/// "set front process, for this window" does go to that window's desktop. It
/// is private, and it is what AltTab and similar switchers use; it is looked up
/// at runtime, so if it ever disappears `focus` returns false and the caller
/// falls back to plain activation.
@MainActor
private enum SkyLight {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFront? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEvent: PostEvent? = symbol("SLPSPostEventRecordTo")
    private static let getPSN: GetPSN? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
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

    /// Brings one specific window to the front, over its siblings.
    ///
    /// Three things have to happen, and the order matters. The app is activated
    /// first: raising a window of an app that is not active only reorders it
    /// inside that app's layer. Activating can in turn put the app's previous
    /// front window back on top, so the window is raised again once that has
    /// settled. And a window on another desktop is invisible to Accessibility
    /// until macOS has switched to that desktop, so the raise is retried while
    /// the switch animates, instead of giving up on the first miss.
    static func raise(_ window: AttachedWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        // Go to this window's own desktop; plain activation is the fallback.
        if !SkyLight.focus(windowID: window.id, pid: window.pid) { activate(app) }
        _ = raiseWindow(window)
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
        // Un-minimize first: raising a minimized window does nothing.
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return true
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

    private static func axWindow(for window: AttachedWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for element in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id == window.id { return element }
        }
        // Fallback when the private call is unavailable: same title.
        return windows.first { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return (title as? String) == window.title && !window.title.isEmpty
        }
    }
}
