import AppKit
import ApplicationServices

/// Maps an Accessibility window to its CGWindowID. Private, but stable since
/// 10.x and used by every window manager on the Mac (AltTab, Rectangle,
/// yabai): there is no public way to go from a capture or CGWindowList id to
/// the window Accessibility can move or raise.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    static func raise(_ window: AttachedWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if hasAccess, let element = axWindow(for: window) {
            // Un-minimize first: raising a minimized window does nothing.
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if app.isHidden { app.unhide() }
        activate(app)
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
