import AppKit

/// Physical description of the notch (or a synthetic one on Macs without it)
/// plus every derived rect the panel needs, all in screen coordinates.
struct NotchGeometry {
    let screen: NSScreen
    /// Size of the physical notch in points.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat
    /// True when the display actually has a notch cut into it.
    let isPhysical: Bool
    /// True when a notch we drew keeps the full menu bar height while
    /// collapsed, the way it used to. Off by default — see `collapsedDepth`.
    let drawsFullSize: Bool

    // MARK: - The icon row
    //
    // Opening the notch first grows it sideways into a pill one notch tall,
    // with the tool icons immediately left and right of the camera. Resting on
    // an icon drops the body down for that tool. The pointer arrives at the
    // notch and never has to leave that row to choose: the old layout put the
    // icons in two rails down the sides of a 620 pt body, so choosing meant
    // going up to open and then down and out to pick.

    /// Width each icon cell gets on the fuller side of the row. The cell is
    /// the hover target, the full height of the row.
    static let iconSlot: CGFloat = 28
    /// Black between the outermost icon and the end of the pill.
    static let rowEndInset: CGFloat = 8
    /// Black between the camera housing and the nearest icon.
    static let rowNotchInset: CGFloat = 6
    /// Gap left in the middle of the row on a display with no notch. There is
    /// no camera to step around, so the sides close up — but not all the way:
    /// the pointer that opened the panel is resting in the middle, and with
    /// an icon under it the dwell would choose that tool on its own.
    static let drawnCenterGap: CGFloat = 48

    /// Width of the middle of the row the icons step around.
    var rowCenterGap: CGFloat {
        isPhysical ? notchSize.width + 2 * Self.rowNotchInset : Self.drawnCenterGap
    }

    /// Width of one side of the row. Both sides take the fuller one's width,
    /// so the pill stays centred on the camera.
    func rowSideWidth(icons: Int) -> CGFloat {
        CGFloat(max(icons, 1)) * Self.iconSlot + Self.rowEndInset
    }

    /// The open-but-not-chosen pill: one row, the notch's own height.
    func pillSize(left: Int, right: Int) -> CGSize {
        CGSize(
            width: rowCenterGap + 2 * rowSideWidth(icons: max(left, right)),
            height: notchSize.height
        )
    }

    // MARK: - The body below the row

    /// The tool's name and counter, between the row and the pane.
    static let captionHeight: CGFloat = 18
    /// Gap between the pane and the bottom edge of the body.
    static let bodyBottomPadding: CGFloat = 14
    /// Gap between the pane and the sides of the body.
    static let bodyHorizontalPadding: CGFloat = 14

    /// Pane area each body size asks for. Held constant across Macs; only the
    /// row on top follows the notch. The body is never narrower than the row:
    /// a body tucked under a wider row leaves two thin ledges either side of
    /// it, and those read as a rendering fault rather than a shape.
    static func paneSize(for size: ToolBodySize) -> CGSize {
        switch size {
        case .compact: CGSize(width: 400, height: 126)
        case .standard: CGSize(width: 512, height: 162)
        case .tall: CGSize(width: 512, height: 354)
        case .wide: CGSize(width: 692, height: 354)
        }
    }

    /// Full body for a tool: row, caption, pane and padding.
    func bodySize(for size: ToolBodySize, rowWidth: CGFloat) -> CGSize {
        let pane = Self.paneSize(for: size)
        return CGSize(
            width: max(rowWidth, pane.width + 2 * Self.bodyHorizontalPadding),
            height: notchSize.height + Self.captionHeight + pane.height + Self.bodyBottomPadding
        )
    }

    /// Largest row the window has to make room for. Generous on purpose: the
    /// window is transparent and click-through outside the panel, so cutting
    /// it once for more icons than anyone runs costs nothing.
    private static let maxIconsPerSide = 8

    /// Widest and tallest body any tab can ask for. The window is cut to this
    /// once and never resized: what is clickable is decided by the active rect.
    var maxBodySize: CGSize {
        let row = pillSize(left: Self.maxIconsPerSide, right: Self.maxIconsPerSide).width
        let all = ToolBodySize.allCases.map { bodySize(for: $0, rowWidth: row) }
        return CGSize(width: all.map(\.width).max() ?? row, height: all.map(\.height).max() ?? notchSize.height)
    }

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// Stable name for the display this geometry was cut from. AppKit hands
    /// out a fresh `NSScreen` for the same monitor on every reconfiguration,
    /// so this is the one thing worth keying a panel on — an index into
    /// `NSScreen.screens` is not, because that array reorders too.
    var displayID: CGDirectDisplayID? { screen.displayID }

    /// Posted when a switch the geometry is built from changes — every display
    /// or one, the full-height notch — so the panels are rebuilt at once
    /// rather than at the next relaunch.
    static let settingsChanged = Notification.Name("CyclopGeometrySettingsChanged")

    /// Persisted in `config.json` (#67) — see `ConfigStore.showOnAllDisplays`
    /// for the default and the reason for it.
    @MainActor
    static var showsOnAllDisplays: Bool {
        get { ConfigStore.shared.showOnAllDisplays }
        set {
            ConfigStore.shared.showOnAllDisplays = newValue
            NotificationCenter.default.post(name: settingsChanged, object: nil)
        }
    }

    /// Persisted in `config.json` as `fullSizeDrawnNotch`. Off by default —
    /// see `collapsedDepth`.
    @MainActor
    static var drawsFullSizeNotch: Bool {
        get { ConfigStore.shared.fullSizeDrawnNotch }
        set {
            ConfigStore.shared.fullSizeDrawnNotch = newValue
            NotificationCenter.default.post(name: settingsChanged, object: nil)
        }
    }

    /// Every display the panel should stand on.
    ///
    /// Switched off, that is the screen with a physical notch if one is
    /// attached and the main display otherwise — the rule from before there
    /// was more than one screen to choose between.
    @MainActor
    static func all() -> [NotchGeometry] {
        // A mirrored display repeats another one's picture, so a panel of its
        // own would be a second copy of the same notch, drawn in the same
        // place, with a second pointer timer behind it.
        let screens = NSScreen.screens.filter { !$0.isMirroring }
        let fullSize = drawsFullSizeNotch
        guard showsOnAllDisplays else {
            let primary = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
            return primary.map { [current(on: $0, drawsFullSize: fullSize)] } ?? []
        }
        return screens.map { current(on: $0, drawsFullSize: fullSize) }
    }

    static func current(on screen: NSScreen, drawsFullSize: Bool) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(
                screen: screen,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchCenterX: screen.frame.minX + left.width + width / 2,
                isPhysical: true,
                drawsFullSize: false
            )
        }

        // No notch: pretend there is one the size of a typical MacBook cutout so
        // the app still works on external displays and pre-2021 machines.
        //
        // The height is the menu bar's own, not `NSStatusBar.thickness`: the two
        // disagree by several points (22 against 30 on a 13" M1 running macOS
        // 26). Collapsed, only a strip of it is drawn — see `collapsedDepth` —
        // but the open panel's header lines up with it, and the full-height
        // notch from Settings is drawn at it, where anything short of the bar
        // reads as a tab stuck onto the menu bar rather than a cutout of it.
        // `visibleFrame` is what the menu bar actually took — measured, not
        // assumed. It collapses to zero when the bar auto-hides, which is what
        // the floor is for.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: 180, height: max(menuBarHeight, NSStatusBar.system.thickness, 24)),
            notchCenterX: screen.frame.midX,
            isPhysical: false,
            drawsFullSize: drawsFullSize
        )
    }

    /// True when nothing that affects the panel has moved. Screen-parameter
    /// notifications fire for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state
    /// and the selected tab.
    func matches(_ other: NotchGeometry) -> Bool {
        screen.frame == other.screen.frame
            && notchSize == other.notchSize
            && notchCenterX == other.notchCenterX
            && isPhysical == other.isPhysical
            && drawsFullSize == other.drawsFullSize
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: maxBodySize.width + windowPadding.left + windowPadding.right,
            height: maxBodySize.height + windowPadding.bottom
        )
    }

    /// Panel frame in global screen coordinates, flush with the top of the display.
    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screen.frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `screen.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screen.frame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Depth of the collapsed notch — both what is drawn and what answers the
    /// pointer, measured down from the top edge.
    ///
    /// A real notch is a hole: nothing is drawn over it, and the whole of it
    /// can be claimed, because there is nothing underneath to claim it from.
    ///
    /// A notch we drew is a strip along the very top edge instead (#109). It
    /// used to be drawn the height of the menu bar, which only holds together
    /// while the bar is there to draw it on — and the bar leaves all the time:
    /// any window in full screen hides it, and on a second display macOS paints
    /// it only while that display has focus. The shape then stood on whatever
    /// was underneath, browser tabs as often as not. Whether the bar is showing
    /// right now is not something a geometry built once can know, so the notch
    /// no longer depends on it: a strip is right with the bar and without.
    ///
    /// The strip is also what answers the pointer, reached by throwing it at
    /// the top edge. The target used to be narrowed to it only when menu bar
    /// icons were measured under the notch; the measurement depended on which
    /// display had focus at the moment of the rebuild, so the same notch
    /// answered in its full height one time and in the top 8 points the next.
    ///
    /// `drawsFullSize` brings the old notch back for anyone who wants it.
    var collapsedDepth: CGFloat {
        isPhysical || drawsFullSize ? notchSize.height : Self.drawnStripDepth
    }

    /// See `collapsedDepth`.
    static let drawnStripDepth: CGFloat = 8

    /// Size of the collapsed notch: the hole itself, or the strip we draw.
    var collapsedSize: CGSize { CGSize(width: notchSize.width, height: collapsedDepth) }

    /// Hover target while collapsed, in global screen coordinates.
    ///
    /// No deeper than the notch itself. A hole used to get 4 pt of slack below
    /// it, so the panel would open just before the pointer landed — but right
    /// below a hole lies the top of whatever window is under the menu bar, and
    /// in a browser that is the tab strip. The slack was the top of the tabs
    /// in the middle of the screen: a pointer resting there, about to click a
    /// tab, opened the panel over the very tab it was clicking.
    var hoverRect: CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - collapsedDepth,
            width: notchSize.width + 12,
            height: collapsedDepth
        ))
    }

    /// Band along the top of the display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives.
    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - 260,
            width: screen.frame.width,
            height: 260
        ))
    }

    /// Area that keeps the panel open, taken for the body actually on screen:
    /// the pill, or the tool's body below it. A rect cut for the pill would
    /// call the pointer "away" the moment it went down into the tool.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}

extension NSScreen {
    /// The display behind this screen, named the way the window server names
    /// it — the same number across every reconfiguration.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// True when this screen only repeats what another display already shows.
    var isMirroring: Bool {
        guard let displayID else { return false }
        return CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
    }
}
