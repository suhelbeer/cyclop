import CoreGraphics
import Foundation

/// Windows the window server still lists but that draw nothing.
///
/// Claude keeps a closed window around (a full-screen one especially) and
/// shows the same window again when it is reopened. While closed it is
/// still listed, off screen, with a desktop of its own, so it looked like a
/// window on another desktop: a preview stuck loading and a dot that a click
/// cannot reach. What gives it away is that it cannot be drawn: a capture of
/// it returns nothing, while every open window, full screen or on another
/// desktop, captures fine (measured on macOS 27.0.1).
///
/// Only windows that are off screen are checked, and one failed capture is
/// not enough (a window going full screen fails once mid-animation): two in
/// a row hide it. Hidden windows are checked again every few seconds, so a
/// reopened window comes back on its own.
struct UndrawnWindows {
    private(set) var hidden: Set<CGWindowID> = []
    private var misses: [CGWindowID: Int] = [:]
    private var lastCheck: [CGWindowID: Date] = [:]

    static let recheck: TimeInterval = 5
    static let missesToHide = 2

    /// The off-screen windows to try capturing now. Windows that are on
    /// screen or gone are forgotten: on screen means drawn.
    mutating func due(offScreen: Set<CGWindowID>, now: Date) -> Set<CGWindowID> {
        hidden.formIntersection(offScreen)
        misses = misses.filter { offScreen.contains($0.key) }
        lastCheck = lastCheck.filter { offScreen.contains($0.key) }
        return offScreen.filter { id in
            // A first miss is confirmed on the very next pass.
            if misses[id] != nil, !hidden.contains(id) { return true }
            return now.timeIntervalSince(lastCheck[id] ?? .distantPast) >= Self.recheck
        }
    }

    mutating func record(_ id: CGWindowID, draws: Bool, now: Date) {
        lastCheck[id] = now
        if draws {
            misses[id] = nil
            hidden.remove(id)
        } else {
            let count = misses[id, default: 0] + 1
            misses[id] = count
            if count >= Self.missesToHide { hidden.insert(id) }
        }
    }

    /// Whether the window can be drawn at all. Copies the window once, so
    /// call it off the main thread.
    static func draws(_ id: CGWindowID) -> Bool {
        OffSpaceCapture.image(of: id, maxEdge: 8) != nil
    }
}
