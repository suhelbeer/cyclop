import CoreGraphics
import Foundation
import Testing
@testable import Cyclop

struct UndrawnWindowsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func everyOffScreenWindowIsCheckedFirstTime() {
        var undrawn = UndrawnWindows()
        #expect(undrawn.due(offScreen: [1, 2], now: t0) == [1, 2])
    }

    /// A window going full screen fails one capture mid-animation.
    @Test func oneMissDoesNotHide() {
        var undrawn = UndrawnWindows()
        _ = undrawn.due(offScreen: [1], now: t0)
        undrawn.record(1, draws: false, now: t0)
        #expect(undrawn.hidden.isEmpty)
        // Confirmed on the next pass, without waiting for the recheck.
        let next = t0.addingTimeInterval(1)
        #expect(undrawn.due(offScreen: [1], now: next) == [1])
        undrawn.record(1, draws: true, now: next)
        #expect(undrawn.hidden.isEmpty)
    }

    @Test func twoMissesHide() {
        var undrawn = UndrawnWindows()
        undrawn.record(1, draws: false, now: t0)
        undrawn.record(1, draws: false, now: t0.addingTimeInterval(1))
        #expect(undrawn.hidden == [1])
    }

    /// Claude reopens a closed window under the same id.
    @Test func reopenedWindowComesBack() {
        var undrawn = UndrawnWindows()
        undrawn.record(1, draws: false, now: t0)
        undrawn.record(1, draws: false, now: t0.addingTimeInterval(1))
        #expect(undrawn.due(offScreen: [1], now: t0.addingTimeInterval(2)).isEmpty)
        let later = t0.addingTimeInterval(1 + UndrawnWindows.recheck)
        #expect(undrawn.due(offScreen: [1], now: later) == [1])
        undrawn.record(1, draws: true, now: later)
        #expect(undrawn.hidden.isEmpty)
    }

    @Test func onScreenWindowIsNeverHidden() {
        var undrawn = UndrawnWindows()
        undrawn.record(1, draws: false, now: t0)
        undrawn.record(1, draws: false, now: t0)
        _ = undrawn.due(offScreen: [], now: t0)
        #expect(undrawn.hidden.isEmpty)
    }

    @Test func drawnWindowIsNotRecheckedEarly() {
        var undrawn = UndrawnWindows()
        undrawn.record(1, draws: true, now: t0)
        #expect(undrawn.due(offScreen: [1], now: t0.addingTimeInterval(1)).isEmpty)
    }
}
