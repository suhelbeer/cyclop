import Testing
@testable import Cyclop

struct NotchCaptionTests {
    // A 200 pt notch with a 40 pt wing: the line is 240 to 440 pt wide.

    @Test func shortCaptionKeepsTheNotchWidth() {
        #expect(NotchContentView.captionWidth(textWidth: 60, notchWidth: 200, wingWidth: 40) == 240)
    }

    @Test func longerCaptionGrowsWithItsText() {
        #expect(NotchContentView.captionWidth(textWidth: 300, notchWidth: 200, wingWidth: 40) == 324)
    }

    @Test func longCaptionStopsAtTwiceTheNotch() {
        #expect(NotchContentView.captionWidth(textWidth: 2000, notchWidth: 200, wingWidth: 40) == 440)
    }

    @MainActor @Test func realBannerTextIsMeasured() {
        let short = NotchContentView.captionTextWidth("Sift app")
        let long = NotchContentView.captionTextWidth("Sift app: My judgment: Sift is already near the point of diminishing returns")
        #expect(short > 20)
        #expect(long > short * 4)
    }
}
