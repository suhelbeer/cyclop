import Foundation
import Testing
@testable import Cyclop

/// Labels as Claude 4.23118 shows them (claude-ax-findings-2026-11-07.md).
struct ClaudeStatusRulesTests {
    private let rules = ClaudeStatusRules.defaults

    @Test func projectWindowWaitingCount() {
        let (reading, _) = rules.classify(["Page tools", "Threads 6 threads waiting on you", "Send"])
        #expect(reading.recognised)
        #expect(reading.waiting == 6)
        #expect(!reading.working)
    }

    @Test func singleThreadWaiting() {
        #expect(rules.classify(["Threads 1 thread waiting on you"]).reading.waiting == 1)
    }

    @Test func mainWindowTasksCount() {
        let (reading, _) = rules.classify(["Tasks, 2 need input", "Needs input, Fix login"])
        #expect(reading.waiting == 2)
        #expect(reading.recognised)
    }

    @Test func workingCardOrStopButton() {
        #expect(rules.classify(["Rename the app — Working"]).reading.working)
        #expect(rules.classify(["Rename the app — View thread — Working — New messages"]).reading.working)
        #expect(rules.classify(["Send", "Stop"]).reading.working)
        let (reading, matched) = rules.classify(["Threads 5 threads waiting on you", "Stop"])
        #expect(reading.working)
        #expect(matched == "Stop")
    }

    /// The word alone, inside a title, is not a state.
    @Test func workingInsideATitleIsNot() {
        #expect(!rules.classify(["Working hours calculator — Needs attention", "Send"]).reading.working)
        #expect(!rules.classify(["Stop the bleeding", "Send"]).reading.working)
        #expect(!rules.classify(["Stopwatch"]).reading.working)
    }

    @Test func quietButRecognised() {
        let (reading, _) = rules.classify(["Add files", "Send"])
        #expect(reading.recognised)
        #expect(!reading.working)
        #expect(reading.waiting == nil)
    }

    /// The main window as a plain chat: no thread cards, no counts.
    @Test func plainChatWindow() {
        let quiet = rules.classify(["Exit incognito", "Retry", "Edit", "Copy", "Send message", "Dictate"]).reading
        #expect(quiet.recognised)
        #expect(!quiet.working)
        #expect(quiet.waiting == nil)
        #expect(rules.classify(["Copy", "Stop response"]).reading.working)
    }

    /// "Send feedback" is on every page, Claude's or not.
    @Test func sendFeedbackProvesNothing() {
        #expect(!rules.classify(["Send feedback"]).reading.recognised)
    }

    @Test func foreignPageIsUnrecognised() {
        let (reading, matched) = rules.classify(["OK", "Cancel", "Help"])
        #expect(reading.readable)
        #expect(!reading.recognised)
        #expect(matched == nil)
    }

    @Test func globMatching() {
        #expect(ClaudeStatusRules.matches("STOP", "stop"))
        #expect(ClaudeStatusRules.matches("Send message", "Send *"))
        #expect(!ClaudeStatusRules.matches("Resend", "Send*"))
        #expect(ClaudeStatusRules.matches("a (b) — Working", "* — Working"))
    }

    @Test func fileKeysAreOptional() throws {
        let data = Data(#"{"working": ["Halt"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ClaudeStatusRules.self, from: data)
        #expect(decoded.working == ["Halt"])
        #expect(decoded.waitingCount == ClaudeStatusRules.defaults.waitingCount)
        #expect(decoded.layout == ClaudeStatusRules.defaults.layout)
    }
}

struct ClaudeActivityTrackerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func reading(working: Bool = false, waiting: Int? = 5) -> ClaudeReading {
        ClaudeReading(readable: true, recognised: true, working: working, waiting: waiting)
    }

    @Test func firstReadingShowsAtOnce() {
        var tracker = ClaudeActivityTracker()
        let changed = tracker.update(reading(working: true), focused: false, now: at(0))
        #expect(changed)
        #expect(tracker.shown == .working)
    }

    /// Projects sit at several waiting threads; that alone is not news.
    @Test func standingWaitingCountIsQuiet() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(waiting: 6), focused: false, now: at(0))
        tracker.update(reading(waiting: 6), focused: false, now: at(10))
        #expect(tracker.shown == .idle)
    }

    @Test func riseInWaitingNeedsYouAfterHold() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(waiting: 5), focused: false, now: at(0))
        tracker.update(reading(waiting: 6), focused: false, now: at(1))
        #expect(tracker.shown == .idle)
        tracker.update(reading(waiting: 6), focused: false, now: at(3.1))
        #expect(tracker.shown == .needsInput)
    }

    @Test func lookingAtTheWindowClearsNeedsYou() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(waiting: 5), focused: false, now: at(0))
        tracker.update(reading(waiting: 6), focused: false, now: at(1))
        tracker.update(reading(waiting: 6), focused: false, now: at(4))
        #expect(tracker.shown == .needsInput)
        tracker.update(reading(waiting: 6), focused: true, now: at(5))
        #expect(tracker.shown == .idle)
        // And the new count is the bar from now on.
        tracker.update(reading(waiting: 6), focused: false, now: at(20))
        #expect(tracker.shown == .idle)
    }

    @Test func countGoingDownLowersTheBar() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(waiting: 6), focused: false, now: at(0))
        tracker.update(reading(waiting: 4), focused: false, now: at(1))
        tracker.update(reading(waiting: 5), focused: false, now: at(2))
        tracker.update(reading(waiting: 5), focused: false, now: at(4.5))
        #expect(tracker.shown == .needsInput)
    }

    /// The Stop button goes for a moment between tool calls.
    @Test func shortGapInWorkIsNotDone() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(working: true), focused: false, now: at(0))
        tracker.update(reading(), focused: false, now: at(1))
        tracker.update(reading(), focused: false, now: at(4))
        #expect(tracker.shown == .working)
        tracker.update(reading(working: true), focused: false, now: at(5))
        tracker.update(reading(), focused: false, now: at(6))
        tracker.update(reading(), focused: false, now: at(11.1))
        #expect(tracker.shown == .done)
    }

    @Test func doneStaysUntilYouLook() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(working: true), focused: false, now: at(0))
        tracker.update(reading(), focused: false, now: at(1))
        tracker.update(reading(), focused: false, now: at(7))
        #expect(tracker.shown == .done)
        tracker.update(reading(), focused: false, now: at(600))
        #expect(tracker.shown == .done)
        tracker.update(reading(), focused: true, now: at(601))
        #expect(tracker.shown == .idle)
    }

    @Test func finishingWhileWatchedIsJustQuiet() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(working: true), focused: true, now: at(0))
        tracker.update(reading(), focused: true, now: at(1))
        tracker.update(reading(), focused: true, now: at(3.5))
        #expect(tracker.shown == .idle)
    }

    @Test func oneFailedReadDoesNotTurnGrey() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(working: true), focused: false, now: at(0))
        tracker.update(.unreadable, focused: false, now: at(1))
        tracker.update(.unreadable, focused: false, now: at(5))
        #expect(tracker.shown == .working)
        tracker.update(.unreadable, focused: false, now: at(9.5))
        #expect(tracker.shown == .unknown)
    }

    @Test func pendingDeadlineIsReported() {
        var tracker = ClaudeActivityTracker()
        tracker.update(reading(), focused: false, now: at(0))
        #expect(tracker.pendingDeadline == nil)
        tracker.update(reading(working: true), focused: false, now: at(1))
        #expect(tracker.pendingDeadline == at(1 + ClaudeActivityTracker.hold))
    }
}
