import AppKit

/// Which scrolls anywhere on screen move the strip, kept apart from the event
/// tap so it can be tested.
///
/// Two kinds: a sideways two-finger swipe while ⌃⌥ is held, wherever the
/// pointer is; and a sideways swipe with no keys over the title bar of a
/// window in view on the strip. Vertical scrolling always passes through, so
/// lists and pages scroll as before.
enum StripGesture {
    /// Height of the band at the top of a window that counts as its title bar.
    static let titleBarHeight: CGFloat = 40

    /// Whether a scroll belongs to the strip. A mouse wheel has no sideways
    /// axis, so with ⌃⌥ held its vertical turn counts too.
    static func claims(modifiersHeld: Bool, overTitleBar: Bool, dx: CGFloat, dy: CGFloat, precise: Bool) -> Bool {
        let sideways = abs(dx) > abs(dy)
        if modifiersHeld { return sideways || !precise }
        return overTitleBar && sideways
    }

    /// True when `point` (Accessibility coordinates) is in the title bar band
    /// of one of `frames`.
    static func isOverTitleBar(_ point: CGPoint, of frames: [CGRect]) -> Bool {
        frames.contains { frame in
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBarHeight).contains(point)
        }
    }
}

/// A system-wide scroll event tap, installed only while the strip is arranged.
///
/// Active (it swallows the scrolls it uses, so the window under the pointer
/// does not scroll too), which needs the Accessibility permission the strip
/// already relies on to move windows. A whole gesture is claimed or passed on
/// as one: the decision is made on its first event, and its momentum follows.
@MainActor
final class StripScrollTap {
    static let shared = StripScrollTap()

    /// Gets each claimed scroll, and whether it is the first of its gesture.
    /// Claimed scrolls are always swallowed.
    var onScroll: ((NSEvent, Bool) -> Void)?
    /// In-view windows, in Accessibility coordinates.
    var frames: () -> [CGRect] = { [] }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Where the trackpad gesture in progress (and its momentum) goes. It is
    /// decided by the first event that actually moves.
    private enum Gesture { case none, undecided, strip, passed }
    private var gesture = Gesture.none

    var isRunning: Bool { tap != nil }

    /// False when macOS refused the tap, which means no Accessibility.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // The tap's source is on the main run loop.
                let passOn = MainActor.assumeIsolated { StripScrollTap.shared.passesOn(type, event) }
                return passOn ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: nil
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        gesture = .none
    }

    /// False to swallow the event.
    private func passesOn(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let pass = true
        // macOS switches a tap off if it is ever slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .scrollWheel, let ns = NSEvent(cgEvent: event) else { return pass }

        // The glide after the fingers lift goes where its gesture went.
        if !ns.momentumPhase.isEmpty {
            let mine = gesture == .strip
            if mine { onScroll?(ns, false) }
            if ns.momentumPhase.contains(.ended) || ns.momentumPhase.contains(.cancelled) { gesture = .none }
            return !mine
        }

        let moved = ns.scrollingDeltaX != 0 || ns.scrollingDeltaY != 0
        if ns.phase.contains(.began) || ns.phase.contains(.mayBegin) { gesture = .undecided }

        if !ns.phase.isEmpty {
            switch gesture {
            case .strip:
                onScroll?(ns, false)
                // Stays the strip's through the glide that may follow.
                return false
            case .passed:
                if ns.phase.contains(.ended) || ns.phase.contains(.cancelled) { gesture = .none }
                return pass
            case .none, .undecided:
                guard moved else { return pass }
                let claimed = claims(event, ns)
                gesture = claimed ? .strip : .passed
                guard claimed else { return pass }
                onScroll?(ns, true)
                return false
            }
        }

        // A mouse wheel: no gesture, each turn decides for itself.
        guard moved, claims(event, ns) else { return pass }
        onScroll?(ns, false)
        return false
    }

    private func claims(_ event: CGEvent, _ ns: NSEvent) -> Bool {
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return StripGesture.claims(
            modifiersHeld: flags == [.maskControl, .maskAlternate],
            overTitleBar: StripGesture.isOverTitleBar(event.location, of: frames()),
            dx: ns.scrollingDeltaX, dy: ns.scrollingDeltaY,
            precise: ns.hasPreciseScrollingDeltas
        )
    }
}
