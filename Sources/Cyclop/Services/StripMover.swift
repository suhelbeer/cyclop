import ApplicationServices
import Foundation
import QuartzCore

/// Moves strip windows smoothly: follows the fingers during a swipe and
/// slides windows into place afterwards.
///
/// Only positions change here, never sizes: a resize makes the other app
/// relayout its whole window, a move does not. Measured on Claude windows, a
/// move reaches the screen within one frame and three windows animate at
/// 40–50 frames a second.
///
/// Everything runs on one serial queue, which owns the cached Accessibility
/// elements (looking a window up costs a round trip to its app, too slow to
/// do every frame).
final class StripMover: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cyclop.strip.mover", qos: .userInteractive)
    private var elements: [CGWindowID: AXUIElement] = [:]
    /// Where each window was last put.
    private var current: [CGWindowID: CGPoint] = [:]
    /// Bumped by every new instruction, so an older slide stops.
    private var generation = 0

    static let slideDuration: TimeInterval = 0.2
    private static let frameInterval: TimeInterval = 1.0 / 60

    /// Puts windows at these positions now, stopping any slide.
    func place(_ targets: [(AttachedWindow, CGPoint)]) {
        queue.async { [self] in
            generation += 1
            for (window, point) in targets where current[window.id] != point { set(point, window) }
        }
    }

    /// Slides each window from where it was last put to its target, easing out.
    func slide(_ targets: [(AttachedWindow, CGPoint)], duration: TimeInterval = StripMover.slideDuration) {
        queue.async { [self] in
            generation += 1
            let mine = generation
            let starts = targets.map { current[$0.0.id] ?? $0.1 }
            let begin = CACurrentMediaTime()
            @Sendable func frame() {
                guard mine == generation else { return }
                let t = min(1, (CACurrentMediaTime() - begin) / duration)
                let eased = 1 - pow(1 - t, 3)
                for ((window, end), start) in zip(targets, starts) {
                    let point = CGPoint(
                        x: (start.x + (end.x - start.x) * eased).rounded(),
                        y: (start.y + (end.y - start.y) * eased).rounded()
                    )
                    if current[window.id] != point { set(point, window) }
                }
                if t < 1 { queue.asyncAfter(deadline: .now() + Self.frameInterval, execute: frame) }
            }
            frame()
        }
    }

    /// Stops any slide, waiting until it has, so a resize that follows does
    /// not race it. Records where windows were put by someone else.
    func stop(noting positions: [CGWindowID: CGPoint] = [:]) {
        queue.sync {
            generation += 1
            current.merge(positions) { $1 }
        }
    }

    func note(_ positions: [CGWindowID: CGPoint]) {
        queue.async { [self] in current.merge(positions) { $1 } }
    }

    func forget() {
        queue.async { [self] in
            generation += 1
            elements = [:]
            current = [:]
        }
    }

    private func set(_ point: CGPoint, _ window: AttachedWindow) {
        guard let element = elements[window.id] ?? StripAX.element(for: window) else { return }
        var value = point
        guard let position = AXValueCreate(.cgPoint, &value) else { return }
        if AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success {
            elements[window.id] = element
            current[window.id] = point
        } else {
            // Stale element (window closed or recreated): look it up next time.
            elements[window.id] = nil
        }
    }
}
