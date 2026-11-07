import Foundation

/// What one Claude window is doing, as the notch shows it.
enum ClaudeActivity: String, Equatable, Sendable {
    /// Nothing readable, or a layout the rules do not recognise. Shown grey:
    /// a guess would be worse than admitting it.
    case unknown
    /// Readable and quiet, or nothing new since you last looked.
    case idle
    /// A thread in this window is running.
    case working
    /// More threads wait on you than when you last looked at this window.
    case needsInput
    /// Work finished while you were looking elsewhere, and nothing new waits
    /// on you. Clears once you go to the window.
    case done

    /// Worth a dot in the folded notch. Idle and unknown windows only get one
    /// while another window has something to say, so the dots keep their order.
    var isNotable: Bool { self == .working || self == .needsInput || self == .done }

    var label: String {
        switch self {
        case .unknown: localized("Unknown")
        case .idle: localized("Quiet")
        case .working: localized("Working")
        case .needsInput: localized("Needs you")
        case .done: localized("Done")
        }
    }
}

/// What a single read of a window found, before any smoothing.
struct ClaudeReading: Equatable, Sendable {
    /// The page answered at all.
    var readable: Bool
    /// Something the rules know was on it, so "nothing found" means quiet
    /// rather than "this is not the page we think it is".
    var recognised: Bool
    /// A thread in the window is running.
    var working: Bool
    /// Threads waiting on you, as Claude counts them. Claude keeps this at a
    /// handful most of the time (finished threads count), so only a rise is
    /// news.
    var waiting: Int?

    static let unreadable = ClaudeReading(readable: false, recognised: false, working: false, waiting: nil)
}

/// Turns a stream of raw readings into the state on screen.
///
/// A raw reading flickers: the Stop button disappears for a moment between
/// tool calls, a card is redrawn, a read times out once. So a new state has
/// to hold for a while before it shows, and "done", a claim about the past,
/// needs Claude to have stayed quiet for longer than a gap between tool
/// calls. Every number here errs on the side of a late dot over a wrong one.
///
/// "Needs you" is a rise in Claude's own waiting count over what it was the
/// last time you were in that window, not the count itself: projects sit at
/// five to seven waiting threads all day, and a dot that is always orange
/// says nothing.
struct ClaudeActivityTracker: Equatable, Sendable {
    /// How long a new state must hold before it shows.
    static let hold: TimeInterval = 2
    /// Quiet needed after working before "done" shows.
    static let doneQuiet: TimeInterval = 5
    /// How long reads must fail before a known state turns grey.
    static let unknownHold: TimeInterval = 8

    private(set) var shown: ClaudeActivity = .unknown
    /// When `shown` last changed; nil until the first reading lands.
    private(set) var shownSince: Date?
    /// The waiting count when you last looked at the window (or when
    /// watching began). A rise over it is "needs you".
    private(set) var seenWaiting: Int?
    /// The latest waiting count read.
    private(set) var waiting: Int?
    private var pending: ClaudeActivity?
    private var pendingSince = Date.distantPast

    init() {}

    /// The state a reading points at, given what is showing now.
    private func target(for reading: ClaudeReading, focused: Bool) -> ClaudeActivity {
        guard reading.readable, reading.recognised else { return .unknown }
        if let count = reading.waiting, let seen = seenWaiting, count > seen { return .needsInput }
        if reading.working { return .working }
        switch shown {
        // Quiet after work you were not watching is news; so it stays
        // until you go to the window.
        case .working, .done: return focused ? .idle : .done
        default: return .idle
        }
    }

    private func holdTime(for target: ClaudeActivity) -> TimeInterval {
        switch target {
        case .done: Self.doneQuiet
        case .unknown: Self.unknownHold
        default: Self.hold
        }
    }

    /// Feeds one reading. `focused` is whether the window is in front, which
    /// counts as having looked at it. Returns true when the shown state
    /// changed.
    @discardableResult
    mutating func update(_ reading: ClaudeReading, focused: Bool, now: Date) -> Bool {
        if let count = reading.waiting, reading.readable {
            waiting = count
            // Looking at the window takes in what it shows; a count that went
            // down (answered elsewhere, on the phone) lowers the bar too.
            if seenWaiting == nil || focused || count < (seenWaiting ?? count) { seenWaiting = count }
        }
        let next = target(for: reading, focused: focused)
        // Going to the window clears what it was holding for you, at once.
        if focused, shown == .done || shown == .needsInput, next != shown {
            return commit(next, now: now)
        }
        if next == shown {
            pending = nil
            return false
        }
        // The first thing ever read shows at once: there is nothing on
        // screen yet for it to flicker against.
        if shownSince == nil, next != .unknown {
            return commit(next, now: now)
        }
        if pending != next {
            pending = next
            pendingSince = now
        }
        guard now.timeIntervalSince(pendingSince) >= holdTime(for: next) else { return false }
        return commit(next, now: now)
    }

    /// When the pending state, if any, would show if nothing changes. The
    /// monitor reads again then, so a state does not wait for the next poll.
    var pendingDeadline: Date? {
        guard let pending else { return nil }
        return pendingSince.addingTimeInterval(holdTime(for: pending))
    }

    private mutating func commit(_ state: ClaudeActivity, now: Date) -> Bool {
        pending = nil
        guard state != shown else { return false }
        shown = state
        shownSince = now
        return true
    }
}
