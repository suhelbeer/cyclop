import Testing
@testable import Cyclop

struct WindowLivenessTests {
    @Test func windowRoleIsReal() {
        #expect(WindowLiveness.verdict(role: "AXWindow") == .real)
    }

    /// What the record of a closed full-screen Claude window reported.
    @Test func unknownRoleIsGhost() {
        #expect(WindowLiveness.verdict(role: "AXUnknown") == .ghost)
    }

    /// A child of a live window also names the window's id; it must not be
    /// taken for the window.
    @Test func childElementIsNotAWindow() {
        #expect(WindowLiveness.verdict(role: "AXGroup") == .ghost)
        #expect(WindowLiveness.verdict(role: "AXWebArea") == .ghost)
    }

    @Test func unreadableRoleIsUnknown() {
        #expect(WindowLiveness.verdict(role: nil) == .unknown)
    }
}
