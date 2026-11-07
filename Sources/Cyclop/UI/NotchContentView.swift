import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// This screen's share of the panel. Everything the pointer decides is
    /// here; everything shown is in `vm`, the same on every display.
    @ObservedObject var panel: PanelState

    private var isOpen: Bool { panel.isActive }
    private var size: CGSize { panel.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    /// Whether the shape is painted at all.
    ///
    /// Folded over a real notch there is nothing to paint: the notch is a hole,
    /// and a hole is already black. The filled shape on top of it is invisible
    /// — but only for as long as what is behind it stays black, and that is not
    /// something the panel gets to assume. The window is `.stationary` and
    /// joins every space, so it stands still while the desktop moves: in
    /// Mission Control and mid-swipe between spaces the desktop shrinks away
    /// and the "notch" is left hanging in the air as a black rectangle over the
    /// Spaces bar. It reads as a second, squarer notch, which is exactly what
    /// it is — a picture of a hole with no hole behind it.
    ///
    /// A drawn notch is the opposite case: there the shape *is* the notch, and
    /// it has to be visible wherever the panel stands. So the rule is narrow —
    /// only the display that has a real cutout, and only while the panel has
    /// nothing of its own to show.
    ///
    /// "Nothing of its own" is asked of the body rather than of `isOpen`, and
    /// the difference is not stylistic. On a hole the body is the notch exactly
    /// when there is nothing to show — folded, `bodySize` is `collapsedSize`,
    /// and on a hole that is the notch itself —
    /// so any future state that grows the folded strip paints itself without
    /// anyone remembering to come back here. Keyed on `isOpen`, the next such
    /// state would draw its text onto a transparent background: white letters
    /// standing on the desktop with nothing behind them.
    private var paintsShape: Bool {
        !panel.geometry.isPhysical || size != panel.geometry.notchSize
    }

    /// The pill is one notch tall, so it gets corners to match: the open
    /// panel's 22 pt bottom radius would not fit in it.
    private var bottomRadius: CGFloat {
        guard isOpen else { return Theme.collapsedBottomRadius }
        return panel.showsBody ? Theme.openBottomRadius : Theme.pillBottomRadius
    }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(paintsShape ? Color.black : Color.clear)
                .frame(width: size.width + 2 * topRadius, height: size.height)
                .shadow(color: .black.opacity(isOpen ? (panel.showsBody ? 0.5 : 0.3) : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                IconRow(vm: vm, panel: panel)
                    // The body is centred on the notch and the row may not
                    // be: keep the row's gap over the camera either way.
                    .offset(x: panel.showsBody ? panel.pillOffset : 0)
                    .opacity(isOpen ? 1 : 0)
                    // Folded, the icons are hidden under the notch strip; a
                    // pointer resting there must open the panel, not choose.
                    .allowsHitTesting(isOpen)
                if isOpen && panel.showsBody {
                    caption
                        .transition(.opacity)
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()

            if !isOpen, let tool = vm.activityTool, let activity = panel.activity {
                activityLayer(tool, activity)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .offset(x: panel.bodyOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.openAnimation, value: panel.showsBody)
        .animation(Theme.openAnimation, value: vm.tab)
        .animation(Theme.openAnimation, value: panel.activity)
    }

    // MARK: - Live activity
    //
    // Folded, a tool may show something beside the camera: Claude's status
    // dots. The wing sits right of the notch, the line under both. The panel
    // opening covers it with the icon row, so it is drawn only folded.

    private func activityLayer(_ tool: any NotchTool, _ activity: NotchActivity) -> some View {
        let notch = panel.geometry.notchSize
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: notch.width)
                tool.activityWing()
                    .frame(width: activity.wingWidth, height: notch.height)
            }
            if let caption = activity.caption {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Moving along the dots swaps the line outright: a
                    // crossfade left two names drawn over each other.
                    .id(caption)
                    .transaction { $0.animation = nil }
                    .padding(.horizontal, 12)
                    .frame(width: notch.width + activity.wingWidth, height: NotchGeometry.activityCaptionHeight, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    // MARK: - Caption
    //
    // The tool's name and its counter, in a slim line between the row and the
    // pane. They used to stand in the notch row itself; the row is the icons'
    // now, and the lit icon already says which tool this is, so the name is
    // kept small enough to read as a label rather than a title bar.

    private var caption: some View {
        HStack(spacing: 0) {
            Text(vm.activeTool.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
                .id(vm.tab)
                .transition(.opacity)
            Spacer(minLength: 0)
            vm.activeTool.headerAccessory()
        }
        .padding(.horizontal, NotchGeometry.bodyHorizontalPadding + 2)
        .frame(height: NotchGeometry.captionHeight)
    }

    // MARK: - Body

    private var content: some View {
        panes
            .padding(.horizontal, NotchGeometry.bodyHorizontalPadding)
            // The body's height is measured from these same numbers, so the
            // two cannot drift apart into a pane that does not fit.
            .padding(.bottom, NotchGeometry.bodyBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The icons sit on both
        // sides of the notch, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var pane: some View {
        vm.activeTool.pane(
            ToolContext(
                vm: vm,
                privacy: vm.privacy,
                wantsKeyboard: $panel.wantsKeyboard,
                isDropTargeted: panel.isDropTargeted
            )
        )
    }
}

/// The tool switcher: icons either side of the notch, in the row the pointer
/// arrives in.
///
/// Hovering chooses, but only after the pointer has stopped: a pointer
/// crossing the row on its way to an icon further out is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
///
/// Hover is the main way in for a second reason: this row lies over the menu
/// bar, and menu bar utilities such as Ice watch for clicks there with a
/// global event monitor, which sees a click whichever window takes it. A click
/// on an icon still works, it may just toggle one of those too.
private struct IconRow: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState

    @State private var hovered: ToolID?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        let row = panel.row
        let geometry = panel.geometry
        HStack(spacing: 0) {
            // Listed nearest the notch first; drawn left to right.
            side(Array(row.left.reversed()), outerEdge: .leading)
            Color.clear.frame(width: geometry.rowCenterGap)
            side(row.right, outerEdge: .trailing)
        }
        .frame(height: geometry.notchSize.height)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending choice along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, panel.isOpen else { return }
            if hovered == vm.tab, panel.isExpanded { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            panel.select(hovered)
        }
    }

    /// One side of the row: equal cells, packed against the notch, with a
    /// little black after the outermost one.
    private func side(_ tools: [any NotchTool], outerEdge: Edge) -> some View {
        HStack(spacing: 0) {
            if outerEdge == .leading { Color.clear.frame(width: NotchGeometry.rowEndInset) }
            ForEach(tools, id: \.id) { tool in
                icon(tool, cellWidth: NotchGeometry.iconSlot)
            }
            if outerEdge == .trailing { Color.clear.frame(width: NotchGeometry.rowEndInset) }
        }
        .frame(width: NotchGeometry.rowSideWidth(icons: tools.count))
    }

    private func icon(_ tool: any NotchTool, cellWidth: CGFloat) -> some View {
        let tab = tool.id
        let isCurrent = panel.showsBody && vm.tab == tab
        return Button {
            panel.select(tab)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isCurrent || hovered == tab ? Color.white : Theme.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isCurrent ? Theme.surfaceHover : hovered == tab ? Theme.surface : .clear)
                )
                // A render-time transform. Growing the frame instead would
                // re-lay out the row on every hover, and layout that runs on
                // pointer movement is exactly the kind that shows up as a
                // stutter.
                .scaleEffect(hovered == tab ? 1.12 : 1)
                // The whole cell, full row height, is the target: the icons
                // are small and sit right at the top edge of the screen.
                .frame(width: cellWidth, height: panel.geometry.notchSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
    }
}
