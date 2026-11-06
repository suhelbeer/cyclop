import CoreGraphics
import Foundation

/// One scroll event, reduced to what the strip needs. Built from a `CGEvent`
/// on the scroll tap's thread or from an `NSEvent` over the notch.
struct ScrollSample: Sendable {
    enum Phase: Sendable { case none, mayBegin, began, changed, ended, cancelled }
    enum Momentum: Sendable { case none, began, changed, ended }

    var dx: CGFloat
    var dy: CGFloat
    /// Trackpad (pixel deltas) rather than a mouse wheel (line steps).
    var precise: Bool
    var phase: Phase = .none
    var momentum: Momentum = .none
    /// The first event of a gesture the tap claimed (its `began` was passed on).
    var starting = false
}

/// What the strip looks like right now, copied out of `WindowStrip` so
/// scrolls can be followed without its (main) thread.
struct StripSnapshot: Sendable {
    var columns: [StripLayout.Column] = []
    var windows: [CGWindowID: AttachedWindow] = [:]
    /// The strip's area, as an Accessibility frame.
    var area: CGRect = .zero
    /// Top of the strip's screen, in Accessibility coordinates.
    var screenTop: CGFloat = 0
    var offset: CGFloat = 0

    var isArranged: Bool { !columns.isEmpty }

    /// The band from the top of the screen down to the windows: the menu bar,
    /// with the notch in it.
    var menuBand: CGRect {
        guard isArranged else { return .null }
        return CGRect(x: area.minX, y: screenTop, width: area.width, height: area.minY + StripLayout.gap - screenTop)
    }

    /// The title bar of every window in view.
    var titleBars: [CGRect] {
        guard isArranged else { return [] }
        let widths = StripLayout.widths(columns, in: area)
        let frames = StripLayout.frames(columns, offset: offset, in: area)
        return StripLayout.visible(widths: widths, offset: offset, available: area.width).map { frames[$0] }
    }
}

/// Follows swipes on a thread of its own: the notch app's main thread draws
/// the panel and previews, and any stall there used to freeze or drop a swipe.
/// Here a swipe only waits for the window moves themselves.
///
/// Main hands it the strip as it stands (`update`); it hands main back where a
/// swipe came to rest (`onRest`) and wheel steps (`onStep`).
final class StripFollower: @unchecked Sendable {
    static let shared = StripFollower()

    /// Where the view stopped, and where the windows were left.
    var onRest: (@MainActor (CGFloat, [CGWindowID: CGRect]) -> Void)?
    var onStep: (@MainActor (Int) -> Void)?
    var mover: StripMover?

    private let queue = DispatchQueue(label: "cyclop.strip.follow", qos: .userInteractive)
    private let lock = NSLock()
    private var shared = StripSnapshot()

    // Queue-only state.
    private struct Swipe {
        let startOffset: CGFloat
        let horizontal: Bool
        var travel: CGFloat = 0
        var frames: [CGWindowID: CGRect] = [:]
        var generation: Int
        var events = 0
    }
    private var swipe: Swipe?
    private var generation = 0
    private var stepper = ScrollStepper()

    /// How long without events before a swipe counts as over: after the
    /// fingers lift with no glide, or a gesture whose end never came.
    private static let idleEnd: TimeInterval = 0.12

    func update(_ snapshot: StripSnapshot) {
        lock.withLock { shared = snapshot }
    }

    var snapshot: StripSnapshot { lock.withLock { shared } }

    func handle(_ sample: ScrollSample) {
        queue.async { [self] in follow(sample) }
    }

    private func follow(_ sample: ScrollSample) {
        let strip = snapshot
        guard strip.isArranged else {
            swipe = nil
            return
        }
        guard sample.precise else {
            let step = stepper.step(dx: sample.dx, dy: sample.dy, precise: false, began: false, momentum: false)
            if step != 0, let onStep { Task { @MainActor in onStep(step) } }
            return
        }

        let gliding = sample.momentum != .none
        // A glide belongs to the swipe before it; without one there is nothing to continue.
        if gliding, swipe == nil { return }
        let begins = sample.starting || sample.phase == .began || sample.phase == .mayBegin
        if begins, swipe != nil { end() }
        if swipe == nil {
            guard sample.phase != .ended, sample.phase != .cancelled else { return }
            generation += 1
            swipe = Swipe(startOffset: strip.offset, horizontal: abs(sample.dx) >= abs(sample.dy), generation: generation)
            // Windows leaving on the left slide under their right-hand neighbours.
            mover?.restack(strip.columns.compactMap { strip.windows[$0.id] }, focus: nil)
        }
        guard var current = swipe else { return }
        current.travel += current.horizontal ? sample.dx : sample.dy
        current.events += 1
        let widths = StripLayout.widths(strip.columns, in: strip.area)
        let shown = StripLayout.rubberBand(
            current.startOffset - current.travel,
            max: StripLayout.maxOffset(widths: widths, available: strip.area.width)
        )
        let frames = StripLayout.frames(strip.columns, offset: shown, in: strip.area)
        var targets: [(AttachedWindow, CGPoint)] = []
        for (column, frame) in zip(strip.columns, frames) {
            current.frames[column.id] = frame
            if let window = strip.windows[column.id] { targets.append((window, frame.origin)) }
        }
        swipe = current
        mover?.place(targets)

        if sample.momentum == .ended {
            end()
        } else {
            // Ends the swipe if nothing else arrives.
            let mine = current.generation
            let count = current.events
            queue.asyncAfter(deadline: .now() + Self.idleEnd) { [self] in
                guard let swipe, swipe.generation == mine, swipe.events == count else { return }
                end()
            }
        }
    }

    private func end() {
        guard let done = swipe else { return }
        swipe = nil
        let stop = done.startOffset - done.travel
        let frames = done.frames
        if let onRest { Task { @MainActor in onRest(stop, frames) } }
    }
}
