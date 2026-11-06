import CoreGraphics

/// Pure geometry of the window strip, kept apart from Accessibility so it can
/// be tested.
///
/// The strip is a row of columns, one window each, laid left to right on one
/// screen. Columns that fit are shown in full; the rest are parked at the
/// screen edge, because macOS will not let a window go fully off screen. The
/// view onto the strip moves a whole column at a time, so no column is ever
/// half on screen.
///
/// The right edge takes a window down to an 8 pt sliver. The left edge does
/// not: macOS pulls a window back until about 260 pt of it shows, so a column
/// parked on the left ends up under the first column in view, and
/// `WindowStrip` raises the columns in view to keep it there.
///
/// All rectangles are Accessibility frames: origin at the top-left of the
/// primary display, y growing downward.
enum StripLayout {
    /// Column widths ⌃⌥R cycles through, as a share of the screen.
    static let presets: [CGFloat] = [1.0 / 3, 1.0 / 2, 2.0 / 3, 1]
    static let defaultPreset = 1
    /// Space between columns and around the strip.
    static let gap: CGFloat = 8
    /// How much of a parked window stays on screen.
    static let sliver: CGFloat = 8

    struct Column: Equatable {
        let id: CGWindowID
        var preset: Int = StripLayout.defaultPreset
        /// The narrowest the window agreed to be, learned by reading its frame
        /// back after a resize. Zero until it refuses one.
        var minWidth: CGFloat = 0
    }

    struct Placement: Equatable {
        /// Index of the leftmost column shown in full.
        let first: Int
        /// One frame per column, in strip order.
        let frames: [CGRect]
        /// Columns shown in full.
        let visible: Set<Int>
    }

    /// Width of a preset on a screen area. Two halves, three thirds or one
    /// full column fill the area exactly, gaps included.
    static func width(preset: Int, in area: CGRect) -> CGFloat {
        let share = presets[min(max(preset, 0), presets.count - 1)]
        return ((area.width - gap) * share - gap).rounded(.down)
    }

    static func width(of column: Column, in area: CGRect) -> CGFloat {
        max(width(preset: column.preset, in: area), column.minWidth)
    }

    static func nextPreset(after preset: Int) -> Int { (preset + 1) % presets.count }

    /// Where a column dragged sideways in a row of previews lands: moved by
    /// the number of whole slots the drag has crossed past halfway.
    static func dropIndex(from index: Int, translation: CGFloat, slot: CGFloat, count: Int) -> Int {
        guard count > 0, slot > 0 else { return index }
        let moved = Int((translation / slot).rounded())
        return min(max(index + moved, 0), count - 1)
    }

    /// `items` with the one at `from` taken out and put back at `to`.
    static func moving<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// Which column to show first so that `focus` is fully on screen.
    ///
    /// The view moves as little as it can: it keeps `current` if the focused
    /// column is already in view, jumps left to the focused column, or slides
    /// right just far enough. When the end of the strip is in view and there is
    /// room to spare, it slides back so no screen space is left empty.
    static func first(widths: [CGFloat], focus: Int, current: Int, available: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        let focus = min(max(focus, 0), widths.count - 1)
        var first = min(max(current, 0), focus)
        while first < focus, span(widths, first...focus) > available { first += 1 }
        let last = lastFitting(widths, from: first, available: available)
        if last == widths.count - 1 {
            while first > 0, span(widths, (first - 1)...last) <= available { first -= 1 }
        }
        return first
    }

    /// Frames for every column, given the focused one and where the view was.
    static func place(_ columns: [Column], focus: Int, current: Int, in area: CGRect) -> Placement {
        let widths = columns.map { width(of: $0, in: area) }
        let first = first(widths: widths, focus: focus, current: current, available: area.width)
        let top = area.minY + gap
        let height = area.height - 2 * gap
        var frames: [CGRect] = []
        var visible = Set<Int>()
        var x = area.minX + gap
        var full = false
        for (index, width) in widths.enumerated() {
            let left: CGFloat
            if index < first {
                left = area.minX + sliver - width
            } else if !full, index == first || x + width + gap <= area.maxX + 0.5 {
                left = x
                x += width + gap
                visible.insert(index)
            } else {
                full = true
                left = area.maxX - sliver
            }
            frames.append(CGRect(x: left, y: top, width: width, height: height))
        }
        return Placement(first: first, frames: frames, visible: visible)
    }

    // MARK: - Continuous view, for following a swipe

    /// Left edge of each column along the strip, the first one at `gap`.
    static func positions(_ widths: [CGFloat]) -> [CGFloat] {
        var x = gap
        return widths.map { width in
            defer { x += width + gap }
            return x
        }
    }

    /// How far along the strip the view is when `first` is the first column shown.
    static func offset(first: Int, positions: [CGFloat]) -> CGFloat {
        positions.indices.contains(first) ? positions[first] - gap : 0
    }

    /// The furthest the view goes: the end of the strip at the right edge.
    static func maxOffset(widths: [CGFloat], available: CGFloat) -> CGFloat {
        guard let last = widths.indices.last else { return 0 }
        return max(0, positions(widths)[last] + widths[last] + gap - available)
    }

    /// Past either end the strip follows the fingers at a third of the speed.
    static func rubberBand(_ offset: CGFloat, max upper: CGFloat) -> CGFloat {
        if offset < 0 { return offset / 3 }
        if offset > upper { return upper + (offset - upper) / 3 }
        return offset
    }

    /// Frames with the view at any offset, while a swipe is under way. A column
    /// partly on screen is drawn where it is; one wholly past an edge is parked
    /// there, as at rest.
    static func frames(_ columns: [Column], offset: CGFloat, in area: CGRect) -> [CGRect] {
        let widths = columns.map { width(of: $0, in: area) }
        let top = area.minY + gap
        let height = area.height - 2 * gap
        return zip(widths, positions(widths)).map { width, position in
            var x = area.minX + position - offset
            if x + width <= area.minX + sliver { x = area.minX + sliver - width }
            if x >= area.maxX - sliver { x = area.maxX - sliver }
            return CGRect(x: x, y: top, width: width, height: height)
        }
    }

    /// The first column to settle on when a swipe ends: whichever puts the view
    /// nearest to where the fingers left it. A swipe that travelled at least
    /// `nudge` moves at least one column, so a short flick is not lost.
    static func settle(
        widths: [CGFloat], offset: CGFloat, startFirst: Int, travel: CGFloat, available: CGFloat, nudge: CGFloat = 40
    ) -> Int {
        guard !widths.isEmpty else { return 0 }
        let positions = positions(widths)
        let last = widths.count - 1
        let maxFirst = first(widths: widths, focus: last, current: last, available: available)
        let candidates = Array(0...maxFirst)
        var best = candidates.min {
            abs(Self.offset(first: $0, positions: positions) - offset) < abs(Self.offset(first: $1, positions: positions) - offset)
        } ?? startFirst
        if best == startFirst, abs(travel) >= nudge {
            // Fingers moving left pull the strip forward.
            best = travel < 0 ? min(startFirst + 1, maxFirst) : max(startFirst - 1, 0)
        }
        return best
    }

    /// The last column shown in full when `first` is the first.
    static func lastVisible(widths: [CGFloat], first: Int, available: CGFloat) -> Int {
        guard widths.indices.contains(first) else { return 0 }
        return lastFitting(widths, from: first, available: available)
    }

    /// Room a run of columns takes, gaps on both sides included.
    private static func span(_ widths: [CGFloat], _ range: ClosedRange<Int>) -> CGFloat {
        widths[range].reduce(0, +) + CGFloat(range.count + 1) * gap
    }

    private static func lastFitting(_ widths: [CGFloat], from first: Int, available: CGFloat) -> Int {
        var last = first
        while last + 1 < widths.count, span(widths, first...(last + 1)) <= available { last += 1 }
        return last
    }
}

/// Turns scroll events over the notch into whole steps along the strip.
///
/// A trackpad sends a stream of small deltas; a mouse wheel sends one per
/// notch. Momentum after the fingers lift is ignored, so a flick moves as far
/// as the fingers did and no further.
struct ScrollStepper {
    /// Points of trackpad travel per step.
    static let threshold: CGFloat = 40
    private var travel: CGFloat = 0

    /// `dx`/`dy` as `NSEvent.scrollingDeltaX/Y`: positive moves content right
    /// or down, which reveals what is to the left, so it steps back.
    /// Returns -1, 0 or +1.
    mutating func step(dx: CGFloat, dy: CGFloat, precise: Bool, began: Bool, momentum: Bool) -> Int {
        if began { travel = 0 }
        guard !momentum else { return 0 }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard delta != 0 else { return 0 }
        guard precise else { return delta > 0 ? -1 : 1 }
        // A change of direction starts over instead of first unwinding.
        if travel != 0, (travel > 0) != (delta > 0) { travel = 0 }
        travel += delta
        guard abs(travel) >= Self.threshold else { return 0 }
        let step = travel > 0 ? -1 : 1
        travel = 0
        return step
    }
}
