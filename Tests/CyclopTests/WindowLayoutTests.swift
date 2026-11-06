import CoreGraphics
import Testing
@testable import Cyclop

struct WindowLayoutTests {
    /// A 1440×900 primary with a 38 pt menu bar and a 70 pt Dock, and a
    /// 1920×1080 display to its right, vertically aligned at the bottom.
    private let primary = WindowLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 792)
    )
    private let external = WindowLayout.Screen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    )

    @Test func cocoaRectBecomesTopLeftRect() {
        let rect = WindowLayout.accessibilityRect(from: primary.visibleFrame, primaryHeight: 900)
        // Menu bar of 38 pt above, so the area starts 38 pt from the top.
        #expect(rect == CGRect(x: 0, y: 38, width: 1440, height: 792))
    }

    @Test func fillTargetsTheScreenTheWindowIsOn() {
        let screens = [primary, external]
        let onPrimary = CGRect(x: 100, y: 100, width: 700, height: 450)
        let onExternal = CGRect(x: 1800, y: 200, width: 700, height: 450)
        #expect(WindowLayout.fillFrame(for: onPrimary, in: screens, primaryHeight: 900)
            == CGRect(x: 0, y: 38, width: 1440, height: 792))
        // The external display's top edge sits above the primary's, so its
        // Accessibility y is negative.
        #expect(WindowLayout.fillFrame(for: onExternal, in: screens, primaryHeight: 900)
            == CGRect(x: 1440, y: -155, width: 1920, height: 1055))
    }

    @Test func aWindowOnNoScreenFallsBackToTheFirst() {
        let stray = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        #expect(WindowLayout.fillFrame(for: stray, in: [primary, external], primaryHeight: 900)
            == CGRect(x: 0, y: 38, width: 1440, height: 792))
    }

    @Test func noScreensMeansNoTarget() {
        #expect(WindowLayout.fillFrame(for: .zero, in: [], primaryHeight: 900) == nil)
    }
}
