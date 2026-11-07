import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Telling a real window from a ghost.
///
/// When a window that was full screen is closed, the window server can keep a
/// record of it at its old size on its old desktop. It is never on screen, it
/// cannot be captured, and the Accessibility element behind it reports the
/// role `AXUnknown` instead of `AXWindow` (measured on macOS 27.0.1 with the
/// Claude desktop app). Left in, it shows in the notch as a window stuck on
/// "loading" that a click cannot reach.
///
/// Only reads: one attribute copy on an element already found.
enum WindowLiveness {
    enum Verdict: Equatable {
        case real
        case ghost
        /// The app did not answer in time, or Accessibility is off. Callers
        /// keep the window: hiding a real one is worse than showing a ghost.
        case unknown
    }

    static func verdict(of element: AXUIElement) -> Verdict {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) {
        case .success:
            return verdict(role: value as? String)
        case .invalidUIElement:
            return .ghost
        default:
            return .unknown
        }
    }

    /// Pulled out so it can be tested without a live window.
    static func verdict(role: String?) -> Verdict {
        guard let role else { return .unknown }
        return role == kAXWindowRole as String ? .real : .ghost
    }

    /// What a search of the app's element ids found for the windows asked about.
    struct SearchResult {
        /// The window element of each id that has one.
        var windows: [CGWindowID: AXUIElement] = [:]
        /// Ids that only have leftovers (elements that still name the window
        /// but are not a window themselves) and no window element.
        var ghosts: Set<CGWindowID> = []
    }

    /// Finds window elements by trying the app's element ids, the way
    /// AltTab reaches windows on other desktops: the app's own window list
    /// only has the ones on the desktop on screen. A token is the pid, a
    /// zero, the tag "coco", then the element id; windows sit in the first
    /// few dozen ids (Claude's at 42–67), and 1000 tries take ~20 ms.
    ///
    /// Every element of a window, not just the window itself, names that
    /// window's id, so only an element with the window role counts. An id
    /// whose elements are all something else is a ghost. An id nothing names
    /// is neither: an app that does not answer this way is not proof.
    static func search(pid: pid_t, for wanted: Set<CGWindowID>, timeout: Float = 0.1) -> SearchResult {
        var result = SearchResult()
        guard !wanted.isEmpty else { return result }
        var leftovers: Set<CGWindowID> = []
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: Int32(pid), toByteOffset: 0, as: Int32.self)
            bytes.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        for elementID: UInt64 in 0..<1000 {
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            // A hung app would make each try wait for the default 6 s.
            AXUIElementSetMessagingTimeout(element, timeout)
            var id: CGWindowID = 0
            let error = _AXUIElementGetWindow(element, &id)
            // The app stopped answering: what was not found stays unknown.
            if error == .cannotComplete { return result }
            guard error == .success, wanted.contains(id), result.windows[id] == nil else { continue }
            switch verdict(of: element) {
            case .real:
                result.windows[id] = element
                if result.windows.count == wanted.count { return result }
            case .ghost:
                leftovers.insert(id)
            case .unknown:
                // Could not tell: not counted either way.
                continue
            }
        }
        result.ghosts = leftovers.subtracting(result.windows.keys)
        return result
    }
}
