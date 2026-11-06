import CoreGraphics

/// Pure geometry of the window strip, kept apart from Accessibility so it can
/// be tested.
///
/// The strip is a row of columns, one window each, laid left to right. The
/// screen is a view onto it that can sit anywhere along it (`offset`, in
/// points from the strip's start): it stays wherever a swipe leaves it, and
/// keys and clicks move it just far enough to show the focused column.
///
/// macOS will not let a window go fully off screen, and the two edges differ:
/// on the right a window can be parked down to an 8 pt sliver, on the left
/// macOS pushes back any window showing less than about 260 pt. Asking for
/// more than that is what made windows twitch, so a column leaving on the left
/// stops at that limit and the next column slides over it (`WindowStrip`
/// stacks the windows left to right so it does).
///
/// All rectangles are Accessibility frames: origin at the top-left of the
/// primary display, y growing downward.
enum StripLayout {
    /// Column widths ⌃⌥R cycles through, as a share of the screen.
    static let presets: [CGFloat] = [1.0 / 3, 1.0 / 2, 2.0 / 3, 1]
    static let defaultPreset = 1
    /// Space between columns and around the strip.
    static let gap: CGFloat = 8
    /// How much of a window parked on the right stays on screen.
    static let sliver: CGFloat = 8
    /// The least macOS lets show of a window at the left edge. Measured on a
    /// 1440 pt wide display, with Claude and Finder windows of every width.
    static let leftKeep: CGFloat = 260
    /// Narrowest width a window's edge can be dragged to and still be kept.
    static let minCustomWidth: CGFloat = 240

    struct Column: Equatable {
        let id: CGWindowID
        var preset: Int = StripLayout.defaultPreset
        /// A width set by dragging the window's edge; wins over the preset.
        var custom: CGFloat?
        /// The narrowest the window agreed to be, learned by reading its frame
        /// back after a resize. Zero until it refuses one.
        var minWidth: CGFloat = 0
    }

    /// Width of a preset on a screen area. Two halves, three thirds or one
    /// full column fill the area exactly, gaps included.
    static func width(preset: Int, in area: CGRect) -> CGFloat {
        let share = presets[min(max(preset, 0), presets.count - 1)]
        return ((area.width - gap) * share - gap).rounded(.down)
    }

    static func width(of column: Column, in area: CGRect) -> CGFloat {
        let chosen = column.custom.map { min(max($0, minCustomWidth), area.width - 2 * gap) }
            ?? width(preset: column.preset, in: area)
        return max(chosen, column.minWidth)
    }

    static func widths(_ columns: [Column], in area: CGRect) -> [CGFloat] {
        columns.map { width(of: $0, in: area) }
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

    // MARK: - The view

    /// Left edge of each column along the strip, the first one at `gap`.
    static func positions(_ widths: [CGFloat]) -> [CGFloat] {
        var x = gap
        return widths.map { width in
            defer { x += width + gap }
            return x
        }
    }

    /// The furthest the view goes: the end of the strip at the right edge.
    static func maxOffset(widths: [CGFloat], available: CGFloat) -> CGFloat {
        guard let last = widths.indices.last else { return 0 }
        return max(0, positions(widths)[last] + widths[last] + gap - available)
    }

    static func clamp(_ offset: CGFloat, widths: [CGFloat], available: CGFloat) -> CGFloat {
        min(max(offset, 0), maxOffset(widths: widths, available: available))
    }

    /// Past either end the strip follows the fingers at a third of the speed.
    static func rubberBand(_ offset: CGFloat, max upper: CGFloat) -> CGFloat {
        if offset < 0 { return offset / 3 }
        if offset > upper { return upper + (offset - upper) / 3 }
        return offset
    }

    /// Where the view goes to show the focused column. With `center`, the
    /// column sits in the middle with its neighbours showing on either side;
    /// otherwise the view moves as little as it can to show it whole. Either
    /// way it stays within the strip, so no screen space is left empty.
    static func reveal(_ focus: Int, widths: [CGFloat], offset: CGFloat, available: CGFloat, center: Bool) -> CGFloat {
        guard widths.indices.contains(focus) else { return 0 }
        let left = positions(widths)[focus]
        let right = left + widths[focus]
        var target = offset
        if center {
            target = (left + right) / 2 - available / 2
        } else if left - gap < offset {
            target = left - gap
        } else if right + gap > offset + available {
            target = right + gap - available
        }
        return clamp(target, widths: widths, available: available)
    }

    /// Every column's frame with the view at `offset`. Columns partly on screen
    /// are drawn where they are. One leaving on the right is parked as a
    /// sliver; one leaving on the left stops where macOS stops it.
    static func frames(_ columns: [Column], offset: CGFloat, in area: CGRect) -> [CGRect] {
        let widths = widths(columns, in: area)
        let top = area.minY + gap
        let height = area.height - 2 * gap
        return zip(widths, positions(widths)).map { width, position in
            var x = area.minX + position - offset
            x = max(x, area.minX + min(leftKeep, width) - width)
            x = min(x, area.maxX - sliver)
            return CGRect(x: x.rounded(), y: top, width: width, height: height)
        }
    }

    /// Columns wholly on screen with the view at `offset`.
    static func visible(widths: [CGFloat], offset: CGFloat, available: CGFloat) -> Set<Int> {
        Set(zip(widths, positions(widths)).enumerated().compactMap { index, column in
            let left = column.1 - offset
            return left >= -0.5 && left + column.0 <= available + 0.5 ? index : nil
        })
    }

    /// How far ⌃⌥− and ⌃⌥= change a width: a twelfth of the screen.
    static func nudged(_ width: CGFloat, by direction: Int, in area: CGRect) -> CGFloat {
        let step = (area.width / 12).rounded()
        return min(max(width + CGFloat(direction) * step, minCustomWidth), area.width - 2 * gap)
    }

    /// A resting view that would leave a window half tucked in at the left
    /// edge moves a little, so that window is either out of sight or shows
    /// the most macOS allows. Mid-swipe it can't be helped: a window showing
    /// less than `leftKeep` is held at that much, and peeks out from behind
    /// the next one until that one reaches the edge.
    static func avoidPeek(_ offset: CGFloat, widths: [CGFloat], available: CGFloat) -> CGFloat {
        for (width, position) in zip(widths, positions(widths)) {
            let right = position + width - offset
            guard position - offset < 0, right > 0.5, right < leftKeep else { continue }
            // Hide it (its neighbour comes to the edge) or show `leftKeep` of it.
            let hide = offset + right + gap
            let show = offset - (leftKeep - right)
            let target = (hide - offset) <= (offset - show) ? hide : show
            return clamp(target, widths: widths, available: available)
        }
        return offset
    }

    /// The column nearest the middle of the screen, which takes focus when a
    /// swipe ends.
    static func nearestToCenter(widths: [CGFloat], offset: CGFloat, available: CGFloat) -> Int {
        let middle = offset + available / 2
        let centres = zip(widths, positions(widths)).map { $0.1 + $0.0 / 2 }
        return centres.indices.min { abs(centres[$0] - middle) < abs(centres[$1] - middle) } ?? 0
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
