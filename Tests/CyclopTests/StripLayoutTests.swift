import CoreGraphics
import Testing
@testable import Cyclop

struct StripLayoutTests {
    /// The visible area of a 1512×982 built-in display with a 38 pt menu bar
    /// and no Dock, as an Accessibility frame.
    private let area = CGRect(x: 0, y: 38, width: 1512, height: 944)
    private let gap = StripLayout.gap

    private func columns(_ presets: [Int]) -> [StripLayout.Column] {
        presets.enumerated().map { StripLayout.Column(id: CGWindowID($0.offset + 1), preset: $0.element) }
    }

    @Test func presetsFillTheAreaExactly() {
        let half = StripLayout.width(preset: 1, in: area)
        let third = StripLayout.width(preset: 0, in: area)
        let full = StripLayout.width(preset: 3, in: area)
        #expect(2 * half + 3 * gap <= area.width)
        #expect(area.width - (2 * half + 3 * gap) < 2)
        #expect(area.width - (3 * third + 4 * gap) < 3)
        #expect(full == area.width - 2 * gap)
    }

    @Test func twoHalvesAreBothInView() {
        let placement = StripLayout.place(columns([1, 1]), focus: 0, current: 0, in: area)
        #expect(placement.visible == [0, 1])
        #expect(placement.frames[0].minX == gap)
        #expect(placement.frames[1].minX == placement.frames[0].maxX + gap)
        #expect(placement.frames.allSatisfy { $0.minY == area.minY + gap && $0.height == area.height - 2 * gap })
    }

    @Test func columnsBeyondTheScreenAreParkedAsSlivers() {
        let placement = StripLayout.place(columns([1, 1, 1, 1]), focus: 0, current: 0, in: area)
        #expect(placement.visible == [0, 1])
        #expect(placement.frames[2].minX == area.maxX - StripLayout.sliver)
        #expect(placement.frames[3].minX == area.maxX - StripLayout.sliver)
    }

    @Test func movingRightSlidesOneColumnAtATime() {
        let cols = columns([1, 1, 1, 1])
        let step1 = StripLayout.place(cols, focus: 2, current: 0, in: area)
        #expect(step1.first == 1)
        #expect(step1.visible == [1, 2])
        // Column 0 is parked at the left edge with a sliver showing.
        #expect(step1.frames[0].maxX == area.minX + StripLayout.sliver)
        let step2 = StripLayout.place(cols, focus: 3, current: step1.first, in: area)
        #expect(step2.visible == [2, 3])
    }

    @Test func movingLeftKeepsTheViewUntilTheFocusLeavesIt() {
        let cols = columns([1, 1, 1, 1])
        // View shows 2 and 3; focusing 2 keeps it, focusing 1 jumps to 1.
        #expect(StripLayout.place(cols, focus: 2, current: 2, in: area).first == 2)
        #expect(StripLayout.place(cols, focus: 1, current: 2, in: area).visible == [1, 2])
    }

    @Test func noEmptySpaceIsLeftAtTheEndOfTheStrip() {
        // Halves, then the last column is narrowed to a third: there is room
        // for the one before as well, so the view slides back to show it.
        let cols = columns([1, 1, 0])
        let placement = StripLayout.place(cols, focus: 2, current: 2, in: area)
        #expect(placement.visible == [1, 2])
    }

    @Test func aFullWidthColumnStandsAlone() {
        let placement = StripLayout.place(columns([1, 3, 1]), focus: 1, current: 0, in: area)
        #expect(placement.visible == [1])
        #expect(placement.frames[1] == CGRect(x: gap, y: area.minY + gap, width: area.width - 2 * gap, height: area.height - 2 * gap))
    }

    @Test func aWindowWiderThanAskedPushesTheNextOneOut() {
        var cols = columns([0, 0, 0])
        // The second window will not go narrower than 700 pt.
        cols[1].minWidth = 700
        let placement = StripLayout.place(cols, focus: 0, current: 0, in: area)
        #expect(placement.frames[1].width == 700)
        #expect(placement.visible == [0, 1])
    }

    @Test func widthCyclesThroughEveryPresetAndWraps() {
        var preset = StripLayout.defaultPreset
        var seen: [Int] = []
        for _ in StripLayout.presets { preset = StripLayout.nextPreset(after: preset); seen.append(preset) }
        #expect(Set(seen).count == StripLayout.presets.count)
        #expect(preset == StripLayout.defaultPreset)
    }

    @Test func emptyStripPlacesNothing() {
        let placement = StripLayout.place([], focus: 0, current: 0, in: area)
        #expect(placement.frames.isEmpty && placement.visible.isEmpty)
    }

    @Test func aWheelNotchIsOneStepAndATrackpadNeedsTravel() {
        var stepper = ScrollStepper()
        // Wheel: scrolling down moves content up, which goes forward.
        #expect(stepper.step(dx: 0, dy: -1, precise: false, began: false, momentum: false) == 1)
        #expect(stepper.step(dx: 0, dy: 1, precise: false, began: false, momentum: false) == -1)
        // Trackpad: small deltas add up, swiping left (content moving left) goes forward.
        #expect(stepper.step(dx: -15, dy: 0, precise: true, began: true, momentum: false) == 0)
        #expect(stepper.step(dx: -15, dy: 2, precise: true, began: false, momentum: false) == 0)
        #expect(stepper.step(dx: -15, dy: 0, precise: true, began: false, momentum: false) == 1)
        // Momentum after the fingers lift is ignored.
        #expect(stepper.step(dx: -80, dy: 0, precise: true, began: false, momentum: true) == 0)
        // Reversing direction starts the count over.
        #expect(stepper.step(dx: -30, dy: 0, precise: true, began: true, momentum: false) == 0)
        #expect(stepper.step(dx: 30, dy: 0, precise: true, began: false, momentum: false) == 0)
        #expect(stepper.step(dx: 15, dy: 0, precise: true, began: false, momentum: false) == -1)
    }
}
