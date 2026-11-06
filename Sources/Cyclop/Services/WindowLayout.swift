import CoreGraphics

/// Pure geometry for placing windows, kept apart from AppKit so it can be
/// tested.
///
/// Two coordinate systems meet here. `NSScreen` frames have their origin at
/// the bottom-left of the primary display and y grows upward. Accessibility
/// and CGWindow frames have it at the top-left of the primary display and y
/// grows downward. The primary display's height is what converts between them.
enum WindowLayout {
    struct Screen: Equatable {
        /// `NSScreen.frame`
        let frame: CGRect
        /// `NSScreen.visibleFrame`: without the menu bar and the Dock.
        let visibleFrame: CGRect
    }

    /// A rectangle in Cocoa coordinates, expressed for Accessibility.
    static func accessibilityRect(from cocoa: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// The screen a window (an Accessibility frame) is mostly on: the one
    /// holding its centre, else the first.
    static func screen(for axFrame: CGRect, in screens: [Screen], primaryHeight: CGFloat) -> Screen? {
        let centre = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return screens.first { $0.frame.contains(centre) } ?? screens.first
    }

    /// Where a window that should fill its screen goes, as an Accessibility frame.
    static func fillFrame(for axFrame: CGRect, in screens: [Screen], primaryHeight: CGFloat) -> CGRect? {
        guard let screen = screen(for: axFrame, in: screens, primaryHeight: primaryHeight) else { return nil }
        return accessibilityRect(from: screen.visibleFrame, primaryHeight: primaryHeight)
    }
}
