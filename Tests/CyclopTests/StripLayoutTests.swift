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

    private func widths(_ cols: [StripLayout.Column]) -> [CGFloat] { StripLayout.widths(cols, in: area) }

    /// Rest frames the way the strip computes them: show the focused column.
    private func rest(_ cols: [StripLayout.Column], focus: Int, from offset: CGFloat = 0, center: Bool = false)
        -> (offset: CGFloat, frames: [CGRect], visible: Set<Int>) {
        let w = widths(cols)
        let o = StripLayout.reveal(focus, widths: w, offset: offset, available: area.width, center: center)
        return (o, StripLayout.frames(cols, offset: o, in: area), StripLayout.visible(widths: w, offset: o, available: area.width))
    }

    @Test func twoHalvesAreBothInView() {
        let r = rest(columns([1, 1]), focus: 0)
        #expect(r.visible == [0, 1])
        #expect(r.frames[0].minX == gap)
        #expect(r.frames[1].minX == r.frames[0].maxX + gap)
        #expect(r.frames.allSatisfy { $0.minY == area.minY + gap && $0.height == area.height - 2 * gap })
    }

    @Test func columnsPastTheRightEdgeAreParkedAsSlivers() {
        let r = rest(columns([1, 1, 1, 1]), focus: 0)
        #expect(r.visible == [0, 1])
        #expect(r.frames[2].minX == area.maxX - StripLayout.sliver)
        #expect(r.frames[3].minX == area.maxX - StripLayout.sliver)
    }

    @Test func focusingPastTheRightEdgeMovesTheViewJustEnough() {
        let cols = columns([1, 1, 1, 1])
        let step = rest(cols, focus: 2)
        #expect(step.visible == [1, 2])
        // Back to column 1: already in view, nothing moves.
        #expect(rest(cols, focus: 1, from: step.offset).offset == step.offset)
        // Column 0: the view goes back to the start.
        #expect(rest(cols, focus: 0, from: step.offset).offset == 0)
    }

    /// The twitch fix: nothing is ever asked to show less than macOS allows
    /// at the left edge, where it would be pushed back.
    @Test func noWindowGoesFurtherLeftThanMacOSAllows() {
        let cols = columns([1, 0, 2, 1, 3])
        let w = widths(cols)
        let maxOffset = StripLayout.maxOffset(widths: w, available: area.width)
        for offset in stride(from: CGFloat(0), through: maxOffset, by: 37) {
            for frame in StripLayout.frames(cols, offset: offset, in: area) {
                #expect(frame.maxX >= area.minX + StripLayout.leftKeep - 0.5)
            }
        }
    }

    @Test func aColumnLeavingOnTheLeftStopsAtTheLimit() {
        let r = rest(columns([1, 1, 1, 1]), focus: 3)
        #expect(r.frames[0].minX == area.minX + StripLayout.leftKeep - r.frames[0].width)
        // Hidden under the first column in view, which starts at the gap.
        #expect(r.frames[1].maxX == r.frames[0].maxX)
        #expect(r.visible == [2, 3])
    }

    @Test func noEmptySpaceIsLeftAtTheEndOfTheStrip() {
        // Halves, then a third: focusing the end shows as much as fits.
        let r = rest(columns([1, 1, 0]), focus: 2)
        #expect(r.frames[2].maxX == area.maxX - gap)
    }

    @Test func centringPutsTheFocusedColumnInTheMiddle() {
        let cols = columns([1, 1, 1, 1, 1])
        let r = rest(cols, focus: 2, center: true)
        #expect(abs(r.frames[2].midX - area.midX) <= 1)
        // Its neighbours show on both sides.
        #expect(r.frames[1].maxX > area.minX + 100 && r.frames[3].minX < area.maxX - 100)
        // The first column cannot be centred without leaving the strip's start empty.
        #expect(rest(cols, focus: 0, center: true).offset == 0)
    }

    @Test func aFullWidthColumnStandsAlone() {
        let r = rest(columns([1, 3, 1]), focus: 1)
        #expect(r.visible == [1])
        #expect(r.frames[1] == CGRect(x: gap, y: area.minY + gap, width: area.width - 2 * gap, height: area.height - 2 * gap))
    }

    @Test func aWindowWiderThanAskedPushesTheNextOneOut() {
        var cols = columns([0, 0, 0])
        cols[1].minWidth = 700
        let r = rest(cols, focus: 0)
        #expect(r.frames[1].width == 700)
        #expect(r.visible == [0, 1])
    }

    @Test func aWidthSetByHandWinsWithinLimits() {
        var cols = columns([1, 1])
        cols[0].custom = 900
        #expect(StripLayout.width(of: cols[0], in: area) == 900)
        cols[0].custom = 50
        #expect(StripLayout.width(of: cols[0], in: area) == StripLayout.minCustomWidth)
        cols[0].custom = 5000
        #expect(StripLayout.width(of: cols[0], in: area) == area.width - 2 * gap)
        // The neighbour starts right after it.
        cols[0].custom = 900
        let r = rest(cols, focus: 0)
        #expect(r.frames[1].minX == gap + 900 + gap)
    }

    @Test func freeScrollStopsAnywhereAndFocusGoesToTheMiddleColumn() {
        let cols = columns([1, 1, 1, 1])
        let w = widths(cols)
        // Stopped a third of the way into column 1.
        let offset: CGFloat = 250
        let frames = StripLayout.frames(cols, offset: offset, in: area)
        #expect(frames[1].minX == gap + w[0] + gap - 250)
        #expect(StripLayout.visible(widths: w, offset: offset, available: area.width) == [1])
        #expect(StripLayout.nearestToCenter(widths: w, offset: offset, available: area.width) == 1)
        // Clamped back inside the ends.
        #expect(StripLayout.clamp(-40, widths: w, available: area.width) == 0)
        #expect(StripLayout.clamp(9999, widths: w, available: area.width) == StripLayout.maxOffset(widths: w, available: area.width))
    }

    @Test func emptyStripPlacesNothing() {
        #expect(StripLayout.frames([], offset: 0, in: area).isEmpty)
        #expect(StripLayout.visible(widths: [], offset: 0, available: area.width).isEmpty)
        #expect(StripLayout.reveal(0, widths: [], offset: 0, available: area.width, center: false) == 0)
    }

    @Test func pastTheEndsTheStripMovesAtAThird() {
        #expect(StripLayout.rubberBand(-90, max: 700) == -30)
        #expect(StripLayout.rubberBand(790, max: 700) == 730)
        #expect(StripLayout.rubberBand(350, max: 700) == 350)
    }

    @Test func widthCyclesThroughEveryPresetAndWraps() {
        var preset = StripLayout.defaultPreset
        var seen: [Int] = []
        for _ in StripLayout.presets { preset = StripLayout.nextPreset(after: preset); seen.append(preset) }
        #expect(Set(seen).count == StripLayout.presets.count)
        #expect(preset == StripLayout.defaultPreset)
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

    @Test func aDragLandsOneSlotOverOncePastHalfway() {
        // Slots of 120 pt, four previews, dragging the second one.
        #expect(StripLayout.dropIndex(from: 1, translation: 50, slot: 120, count: 4) == 1)
        #expect(StripLayout.dropIndex(from: 1, translation: 70, slot: 120, count: 4) == 2)
        #expect(StripLayout.dropIndex(from: 1, translation: 250, slot: 120, count: 4) == 3)
        #expect(StripLayout.dropIndex(from: 1, translation: -70, slot: 120, count: 4) == 0)
        // Past either end it stops at the end.
        #expect(StripLayout.dropIndex(from: 1, translation: 900, slot: 120, count: 4) == 3)
        #expect(StripLayout.dropIndex(from: 1, translation: -900, slot: 120, count: 4) == 0)
    }

    @Test func movingKeepsEveryItemOnce() {
        #expect(StripLayout.moving([1, 2, 3, 4], from: 0, to: 2) == [2, 3, 1, 4])
        #expect(StripLayout.moving([1, 2, 3, 4], from: 3, to: 0) == [4, 1, 2, 3])
        #expect(StripLayout.moving([1, 2, 3], from: 1, to: 1) == [1, 2, 3])
        #expect(StripLayout.moving([1, 2, 3], from: 1, to: 7) == [1, 2, 3])
    }

    @Test func whichScrollsBelongToTheStrip() {
        typealias G = StripGesture
        // ⌃⌥ held: sideways anywhere, and a mouse wheel's turn too.
        #expect(G.claims(modifiersHeld: true, zone: .none, dx: -6, dy: 1, precise: true))
        #expect(G.claims(modifiersHeld: true, zone: .none, dx: 0, dy: -1, precise: false))
        #expect(!G.claims(modifiersHeld: true, zone: .none, dx: 1, dy: -8, precise: true))
        // Over the menu bar: any direction, trackpad or wheel.
        #expect(G.claims(modifiersHeld: false, zone: .menuBar, dx: 0, dy: 5, precise: true))
        #expect(G.claims(modifiersHeld: false, zone: .menuBar, dx: -5, dy: 0, precise: true))
        #expect(G.claims(modifiersHeld: false, zone: .menuBar, dx: 0, dy: 1, precise: false))
        // Over a title bar: sideways only.
        #expect(G.claims(modifiersHeld: false, zone: .titleBar, dx: 5, dy: 0, precise: true))
        #expect(!G.claims(modifiersHeld: false, zone: .titleBar, dx: 0, dy: 5, precise: true))
        #expect(!G.claims(modifiersHeld: false, zone: .titleBar, dx: 0, dy: 1, precise: false))
        // Anywhere else, nothing.
        #expect(!G.claims(modifiersHeld: false, zone: .none, dx: 9, dy: 0, precise: true))
    }

    @Test func zonesAreTheMenuBarAndTheTitleBarsInView() {
        let band = CGRect(x: 0, y: 0, width: 1440, height: 37)
        let frames = [CGRect(x: 8, y: 37, width: 708, height: 887), CGRect(x: 724, y: 37, width: 708, height: 887)]
        #expect(StripGesture.zone(of: CGPoint(x: 720, y: 10), menuBand: band, titleBars: frames) == .menuBar)
        #expect(StripGesture.zone(of: CGPoint(x: 1400, y: 2), menuBand: band, titleBars: frames) == .menuBar)
        #expect(StripGesture.zone(of: CGPoint(x: 300, y: 50), menuBand: band, titleBars: frames) == .titleBar)
        #expect(StripGesture.zone(of: CGPoint(x: 1000, y: 76), menuBand: band, titleBars: frames) == .titleBar)
        #expect(StripGesture.zone(of: CGPoint(x: 300, y: 200), menuBand: band, titleBars: frames) == .none)
        #expect(StripGesture.zone(of: CGPoint(x: 720, y: 50), menuBand: band, titleBars: frames) == .none)
    }

    @Test func theMenuBandReachesFromTheScreenTopToTheWindows() {
        var snapshot = StripSnapshot()
        snapshot.columns = columns([1, 1])
        snapshot.area = area
        snapshot.screenTop = 0
        #expect(snapshot.menuBand == CGRect(x: 0, y: 0, width: area.width, height: area.minY + gap))
        #expect(snapshot.titleBars.count == 2)
        #expect(StripSnapshot().menuBand.isNull)
    }

    @Test func aRestingViewNeverLeavesAWindowHalfTuckedAtTheLeft() {
        let cols = columns([1, 1, 1, 1])
        let w = widths(cols)
        let maxOffset = StripLayout.maxOffset(widths: w, available: area.width)
        for stop in stride(from: CGFloat(0), through: maxOffset, by: 13) {
            let rest = StripLayout.avoidPeek(stop, widths: w, available: area.width)
            for (width, position) in zip(w, StripLayout.positions(w)) {
                let right = position + width - rest
                // Either out of sight, or showing at least what macOS keeps.
                #expect(right <= 0.5 + StripLayout.gap || right >= StripLayout.leftKeep - 0.5 || position - rest >= 0)
            }
            // It only ever moves a little.
            #expect(abs(rest - stop) <= StripLayout.leftKeep)
        }
    }

    @Test func narrowerAndWiderStepByATwelfthWithinLimits() {
        let step = (area.width / 12).rounded()
        #expect(StripLayout.nudged(700, by: 1, in: area) == 700 + step)
        #expect(StripLayout.nudged(700, by: -1, in: area) == 700 - step)
        #expect(StripLayout.nudged(StripLayout.minCustomWidth, by: -1, in: area) == StripLayout.minCustomWidth)
        #expect(StripLayout.nudged(area.width, by: 1, in: area) == area.width - 2 * gap)
    }
}
