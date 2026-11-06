import AppKit

/// Which scrolls anywhere on screen move the strip, kept apart from the event
/// tap so it can be tested.
///
/// With ⌃⌥ held, a sideways swipe anywhere. With no keys, any swipe or wheel
/// turn over the menu bar (notch included), and a sideways swipe over the
/// title bar of a window in view. Everything else passes through, so lists and
/// pages scroll as before.
enum StripGesture {
    enum Zone { case none, menuBar, titleBar }

    /// Height of the band at the top of a window that counts as its title bar.
    static let titleBarHeight: CGFloat = 40

    /// Whether a scroll belongs to the strip. A mouse wheel has no sideways
    /// axis, so where it counts, its vertical turn does.
    static func claims(modifiersHeld: Bool, zone: Zone, dx: CGFloat, dy: CGFloat, precise: Bool) -> Bool {
        let sideways = abs(dx) > abs(dy)
        if modifiersHeld { return sideways || !precise }
        switch zone {
        // Nothing in the menu bar scrolls, so any direction can be taken.
        case .menuBar: return true
        case .titleBar: return sideways
        case .none: return false
        }
    }

    /// Which zone `point` (Accessibility coordinates) is in.
    static func zone(of point: CGPoint, menuBand: CGRect, titleBars: [CGRect]) -> Zone {
        if menuBand.contains(point) { return .menuBar }
        let overTitle = titleBars.contains { frame in
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBarHeight).contains(point)
        }
        return overTitle ? .titleBar : .none
    }
}

/// A system-wide scroll event tap, installed only while the strip is arranged.
///
/// It runs on a thread of its own, so it answers macOS at once however busy
/// the notch is: a tap that is slow to answer gets switched off by macOS, and
/// swipes then went missing until it was switched back on. Claimed gestures go
/// to `StripFollower`, also off the main thread.
///
/// Active (it swallows the scrolls it uses, so the window under the pointer
/// does not scroll too), which needs the Accessibility permission the strip
/// already relies on to move windows. A whole gesture is claimed or passed on
/// as one: the first event that moves decides, and its glide follows.
final class StripScrollTap: @unchecked Sendable {
    static let shared = StripScrollTap()

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    // Tap-thread state.
    private enum Gesture { case none, undecided, strip, passed }
    private var gesture = Gesture.none

    /// False when macOS refused the tap, which means no Accessibility.
    @discardableResult
    func start() -> Bool {
        if lock.withLock({ tap != nil }) { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                StripScrollTap.shared.passesOn(type, event) ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: nil
        ) else { return false }
        lock.withLock { tap = port }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            guard let port = lock.withLock({ tap }) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.withLock { runLoop = CFRunLoopGetCurrent() }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "cyclop.strip.scroll-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                tap = nil
                runLoop = nil
            }
            return (tap, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// False to swallow the event. Runs on the tap's thread.
    private func passesOn(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // macOS switches a tap off if it is ever slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        guard type == .scrollWheel else { return true }
        var sample = Self.sample(event)

        if sample.momentum != .none {
            let mine = gesture == .strip
            if mine { StripFollower.shared.handle(sample) }
            if sample.momentum == .ended { gesture = .none }
            return !mine
        }

        let moved = sample.dx != 0 || sample.dy != 0
        if sample.phase == .began || sample.phase == .mayBegin { gesture = .undecided }

        if sample.phase != .none {
            switch gesture {
            case .strip:
                StripFollower.shared.handle(sample)
                return false
            case .passed:
                if sample.phase == .ended || sample.phase == .cancelled { gesture = .none }
                return true
            case .none, .undecided:
                guard moved else { return true }
                guard claims(event, sample) else {
                    gesture = .passed
                    return true
                }
                gesture = .strip
                sample.starting = true
                StripFollower.shared.handle(sample)
                return false
            }
        }

        // A mouse wheel: no gesture, each turn decides for itself.
        guard moved, claims(event, sample) else { return true }
        StripFollower.shared.handle(sample)
        return false
    }

    private func claims(_ event: CGEvent, _ sample: ScrollSample) -> Bool {
        let strip = StripFollower.shared.snapshot
        guard strip.isArranged else { return false }
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return StripGesture.claims(
            modifiersHeld: flags == [.maskControl, .maskAlternate],
            zone: StripGesture.zone(of: event.location, menuBand: strip.menuBand, titleBars: strip.titleBars),
            dx: sample.dx, dy: sample.dy, precise: sample.precise
        )
    }

    /// The scroll fields of a `CGEvent`, read directly: `NSEvent` is not meant
    /// to be built off the main thread.
    static func sample(_ event: CGEvent) -> ScrollSample {
        let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let dx = precise
            ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            : event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let dy = precise
            ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            : event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let phase: ScrollSample.Phase = switch event.getIntegerValueField(.scrollWheelEventScrollPhase) {
        case 1: .began
        case 2: .changed
        case 4: .ended
        case 8: .cancelled
        case 128: .mayBegin
        default: .none
        }
        let momentum: ScrollSample.Momentum = switch event.getIntegerValueField(.scrollWheelEventMomentumPhase) {
        case 1: .began
        case 2: .changed
        case 3: .ended
        default: .none
        }
        return ScrollSample(dx: CGFloat(dx), dy: CGFloat(dy), precise: precise, phase: phase, momentum: momentum)
    }
}
