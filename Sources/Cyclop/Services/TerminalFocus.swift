import AppKit
import ApplicationServices

/// Brings a Claude Code session's window to the front.
///
/// Terminal and iTerm2 can be asked over AppleScript for the tab that owns a
/// tty, so a click lands on the exact tab. That asks for the Automation
/// permission once per terminal app. Anything else (an editor's built-in
/// terminal, Ghostty, Warp) is brought forward as an app, and if Cyclop
/// already holds Accessibility, the window whose title names the project is
/// raised. Accessibility is never requested from here.
@MainActor
enum TerminalFocus {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"

    static func focus(_ session: ClaudeSession) {
        guard let bundleID = session.appBundleID else { return }
        if let tty = session.tty {
            if bundleID == terminal, run(terminalScript(tty: tty)) { return }
            if bundleID == iTerm, run(iTermScript(tty: tty)) { return }
        }
        let project = session.project
        activate(bundleID: bundleID) {
            raiseWindow(bundleID: bundleID, titleContaining: project)
        }
    }

    // MARK: - AppleScript

    /// The tty is checked against `^/dev/ttys?[0-9]+$` when the session file is
    /// parsed, so it is safe to put inside a script literal.
    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// True when the script found the tab. False on "not found" and on any
    /// error, including a refused Automation permission, so the caller can
    /// fall back to activating the app.
    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    // MARK: - Generic apps

    /// Through `openApplication` rather than `NSRunningApplication.activate`:
    /// since macOS 14 an app that is not frontmost (Cyclop never is) may have a
    /// plain activate request ignored.
    private static func activate(bundleID: String, then: @escaping @MainActor @Sendable () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in then() }
        }
    }

    private static func raiseWindow(bundleID: String, titleContaining needle: String) {
        guard AXIsProcessTrusted(), !needle.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, text.localizedCaseInsensitiveContains(needle) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }
}
