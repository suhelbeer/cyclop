import Testing
@testable import Cyclop

/// The split of icons either side of the notch. Only the arithmetic: how the
/// row looks is checked by eye, like the rest of the panel.
struct NotchRowTests {
    private func split(_ count: Int, pinned: Set<Int> = []) -> (left: [Int], right: [Int]) {
        NotchViewModel.splitRow(Array(0..<count), pinnedRight: { pinned.contains($0) })
    }

    @Test func nearestSpotsAlternateStartingLeft() {
        let row = split(4)
        #expect(row.left == [0, 2])
        #expect(row.right == [1, 3])
    }

    @Test func pinnedGoesToTheFarRightEnd() {
        let row = split(5, pinned: [0])
        #expect(row.right.last == 0)
        #expect(!row.left.contains(0))
    }

    /// The pill is as wide as its fuller side twice, so the sides may differ by
    /// one icon at most, and every item lands exactly once.
    @Test func sidesStayWithinOneOfEachOther() {
        for count in 1...16 {
            for pinned in [Set<Int>(), Set([count - 1]), Set([0, count - 1])] {
                let row = split(count, pinned: pinned)
                #expect(row.left.count + row.right.count == count)
                #expect(Set(row.left + row.right).count == count)
                // Only when more is pinned right than the right side has room
                // for can the sides drift apart — two pinned out of two, say.
                let rightRoom = count - (count + 1) / 2
                if pinned.count <= rightRoom {
                    #expect(row.left.count - row.right.count == count % 2, "count \(count) pinned \(pinned)")
                }
            }
        }
    }

    /// Eleven tools with Settings pinned — what most people run.
    @Test func elevenToolsWithSettings() {
        let row = split(11, pinned: [10])
        #expect(row.left.count == 6)
        #expect(row.right.count == 5)
        #expect(row.right.last == 10)
        #expect(row.left.first == 0)
        #expect(row.right.first == 1)
    }
}
