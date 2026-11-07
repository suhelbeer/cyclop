import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One Claude window as one read found it.
struct ClaudeWindowReading: Equatable, Sendable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let reading: ClaudeReading
    /// The label that decided `reading`, for Settings.
    let matched: String?
}

/// What one pass over Claude found.
struct ClaudeReadResult: Sendable {
    let pid: pid_t
    let windows: [ClaudeWindowReading]
    /// Claude's focused window, if Claude answered.
    let focusedWindow: CGWindowID?
    let duration: TimeInterval
}

/// Reads Claude's windows through Accessibility, and nothing else.
///
/// **Read-only.** Every call here copies an attribute or runs a search. The
/// one write in the whole feature is `AXManualAccessibility`, set by the
/// monitor, the same switch a screen reader flips. Nothing is pressed,
/// focused, raised or typed.
///
/// Runs on its own serial queue so a slow Claude never holds up the panel,
/// and every element it touches gets a 0.25 s timeout so it never waits on
/// Claude for long either.
final class ClaudeAXReader: @unchecked Sendable {
    static let timeout: Float = 0.25

    private let queue = DispatchQueue(label: "cyclop.claude-status", qos: .utility)

    // Touched only on `queue`.
    private var pid: pid_t = 0
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var webAreas: [CGWindowID: [AXUIElement]] = [:]
    /// Windows that had a page once. A window without one is one of
    /// Electron's thin edge helpers, unless it is one of these and Claude is
    /// just slow to answer right now.
    private var real: Set<CGWindowID> = []
    /// Windows where the button search finds nothing the rules know (the
    /// main window's search came back empty in the probe): walked instead.
    private var walked: Set<CGWindowID> = []
    /// Records the window server kept for windows that were closed (see
    /// `WindowLiveness`): never read, never shown.
    private var ghosts: Set<CGWindowID> = []
    private var lastSearch = Date.distantPast
    private var busy = false

    /// Reads every Claude window of `pid` and hands the result to `done` on
    /// the main queue. A call made while a read is still running is dropped:
    /// the monitor asks again on its next event or tick.
    func read(pid: pid_t, rules: ClaudeStatusRules.Compiled, done: @escaping @Sendable (ClaudeReadResult) -> Void) {
        queue.async { [self] in
            guard !busy else { return }
            busy = true
            let result = readNow(pid: pid, rules: rules)
            busy = false
            DispatchQueue.main.async { done(result) }
        }
    }

    func forget() {
        queue.async { [self] in
            elements.removeAll()
            webAreas.removeAll()
            real.removeAll()
            walked.removeAll()
            ghosts.removeAll()
            lastSearch = .distantPast
        }
    }

    // MARK: - On the queue

    private func readNow(pid: pid_t, rules: ClaudeStatusRules.Compiled) -> ClaudeReadResult {
        let start = Date()
        currentRules = rules
        if pid != self.pid {
            self.pid = pid
            elements.removeAll()
            webAreas.removeAll()
            real.removeAll()
            walked.removeAll()
            ghosts.removeAll()
            lastSearch = .distantPast
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)

        let all = standardWindows(pid: pid)
        locate(all.map(\.id), app: app, pid: pid)
        let windows = all.filter { !ghosts.contains($0.id) }

        var readings: [ClaudeWindowReading] = []
        for window in windows {
            // Not found yet (another desktop, before the next search): left
            // out rather than shown as a nameless grey dot.
            guard let element = elements[window.id] else { continue }
            // A window that has closed since it was found: let the next
            // search decide whether a ghost of it is all that is left.
            if WindowLiveness.verdict(of: element) == .ghost {
                elements[window.id] = nil
                webAreas[window.id] = nil
                continue
            }
            let title = string(element, kAXTitleAttribute) ?? ""
            guard let labels = labels(in: window.id, element: element) else {
                if real.contains(window.id) {
                    readings.append(.init(id: window.id, title: title, frame: window.frame, reading: .unreadable, matched: nil))
                }
                continue
            }
            real.insert(window.id)
            let (reading, matched) = rules.classify(labels)
            readings.append(.init(id: window.id, title: title, frame: window.frame, reading: reading, matched: matched))
        }

        var focused: CGWindowID?
        if let raw = value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            focused = windowID(raw as! AXUIElement)
        }
        return ClaudeReadResult(pid: pid, windows: readings, focusedWindow: focused, duration: Date().timeIntervalSince(start))
    }

    /// Claude's ordinary windows on every desktop, from the window server.
    /// Sizes rule out the invisible helper windows Electron keeps around.
    private func standardWindows(pid: pid_t) -> [(id: CGWindowID, frame: CGRect)] {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var found: [(CGWindowID, CGRect)] = []
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 320, bounds.height >= 240
            else { continue }
            found.append((CGWindowID(number), bounds))
        }
        return found
    }

    /// Finds an Accessibility element for every window id. The app's own
    /// window list only has the windows on the current desktop; the rest are
    /// found by trying element ids, as `WindowFocus` does, at most every 15 s.
    /// Ids that turn out to be ghosts are dropped for good.
    private func locate(_ ids: [CGWindowID], app: AXUIElement, pid: pid_t) {
        ghosts.formIntersection(ids)
        let wanted = Set(ids).subtracting(ghosts)
        elements = elements.filter { wanted.contains($0.key) }
        webAreas = webAreas.filter { wanted.contains($0.key) }
        real.formIntersection(wanted)
        walked.formIntersection(wanted)
        for element in (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            if let id = windowID(element), wanted.contains(id) { elements[id] = element }
        }
        let missing = wanted.subtracting(elements.keys)
        guard !missing.isEmpty, Date().timeIntervalSince(lastSearch) > 15 else { return }
        lastSearch = Date()
        let found = WindowLiveness.search(pid: pid, for: missing)
        for (id, element) in found.windows {
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            elements[id] = element
        }
        ghosts.formUnion(found.ghosts)
    }

    /// The labels of the controls on the window's page, or nil when there is
    /// no page or it cannot be read (Claude busy, Mac locked).
    ///
    /// The cheap way first: Chromium's own search for buttons and toggles,
    /// a few milliseconds a window. Where that finds nothing the rules know,
    /// the page is walked instead (about 50 ms), and that window stays walked.
    private func labels(in id: CGWindowID, element: AXUIElement) -> [String]? {
        guard let areas = pages(for: id, window: element), !areas.isEmpty else { return nil }
        if !walked.contains(id) {
            var found: [String] = []
            var failed = false
            for area in areas {
                guard let labels = searchControls(in: area) else { failed = true; break }
                found += labels
            }
            if failed {
                webAreas[id] = nil
                return nil
            }
            if !found.isEmpty, recognisable(found) { return found }
            walked.insert(id)
        }
        var found: [String] = []
        for area in areas { found += walk(area) }
        if found.isEmpty { webAreas[id] = nil }
        return found
    }

    /// Set by `readNow` for `recognisable`: the rules of the read in flight.
    private var currentRules: ClaudeStatusRules.Compiled?

    private func recognisable(_ labels: [String]) -> Bool {
        guard let currentRules else { return true }
        return currentRules.classify(labels).reading.recognised
    }

    private func searchControls(in area: AXUIElement) -> [String]? {
        func search(_ key: Any) -> [AXUIElement]? {
            let params: NSDictionary = [
                "AXSearchKey": key,
                "AXResultsLimit": NSNumber(value: 600),
                "AXDirection": "AXDirectionNext",
                "AXImmediateDescendantsOnly": NSNumber(value: false),
                "AXVisibleOnly": NSNumber(value: false),
            ]
            var raw: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString, params, &raw)
            guard error == .success else { return nil }
            return raw as? [AXUIElement] ?? []
        }
        // Several keys in one search where Chromium takes a list, one at a
        // time where it does not.
        let elements: [AXUIElement]
        if let both = search(["AXButtonSearchKey", "AXCheckBoxSearchKey"] as NSArray) {
            elements = both
        } else {
            guard let buttons = search("AXButtonSearchKey") else { return nil }
            elements = buttons + (search("AXCheckBoxSearchKey") ?? [])
        }
        return elements.compactMap(label)
    }

    private static let walkedRoles: Set<String> = ["AXButton", "AXCheckBox", "AXLink", "AXStaticText", "AXHeading", "AXImage"]
    private static let walkCap = 2500
    private static let nodeKeys: [String] = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute]

    /// Every control's label and every short text on the page. Long texts
    /// are chat content: skipped, never kept.
    private func walk(_ area: AXUIElement) -> [String] {
        var labels: [String] = []
        var stack = [area]
        var visited = 0
        // A walk is a few hundred calls; a Claude that has stopped answering
        // would make each wait out its timeout. Give up on the first one, and
        // on the whole walk after half a second.
        let deadline = Date().addingTimeInterval(0.5)
        while let element = stack.popLast(), visited < Self.walkCap {
            visited += 1
            if visited % 50 == 0, Date() > deadline { break }
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, Self.nodeKeys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            if error == .cannotComplete { break }
            guard error == .success, let values = raw as? [AnyObject], values.count == 5 else { continue }
            let role = values[0] as? String ?? ""
            if Self.walkedRoles.contains(role) {
                let texts = [values[1], values[2]] + (role == "AXStaticText" ? [values[3]] : [])
                if let text = texts.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }), text.count <= 160 {
                    labels.append(text)
                }
            }
            if let children = values[4] as? [AXUIElement] { stack.append(contentsOf: children.reversed()) }
        }
        return labels
    }

    /// Every page in the window. The main window has two at different
    /// depths: the app's own shell (empty) and, a level further down, the
    /// claude.ai page inside it. So the whole top of the tree is searched,
    /// not just the first level that has a page.
    private func pages(for id: CGWindowID, window: AXUIElement) -> [AXUIElement]? {
        if let cached = webAreas[id], let first = cached.first, string(first, kAXRoleAttribute) == "AXWebArea" { return cached }
        var found: [AXUIElement] = []
        var level = [window]
        for _ in 0..<12 where !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    AXUIElementSetMessagingTimeout(child, Self.timeout)
                    if string(child, kAXRoleAttribute) == "AXWebArea" { found.append(child) }
                    next.append(child)
                }
            }
            level = Array(next.prefix(200))
        }
        guard !found.isEmpty else { return nil }
        webAreas[id] = found
        return found
    }

    // MARK: - Helpers

    private static let labelKeys: [String] = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]

    /// Title, then description, then help: whichever the page filled in.
    private func label(_ element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.labelKeys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject]
        else { return nil }
        for item in values {
            if let text = item as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    private func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
}
