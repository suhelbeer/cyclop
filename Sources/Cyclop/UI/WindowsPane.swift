import SwiftUI

/// A strip of small live previews on top, one large preview below. The large
/// one follows the pointer over the strip and stays on the last window
/// pointed at, so moving down onto it to click does not swap it out.
struct WindowsPane: View {
    @ObservedObject var store: WindowStore
    @ObservedObject private var strip = WindowStrip.shared
    @State private var editing = false
    /// The window in the large preview.
    @State private var focused: CGWindowID?
    /// The preview being dragged to reorder the strip, and how far.
    @State private var dragging: CGWindowID?
    @State private var dragX: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if !store.hasScreenAccess {
                    accessPrompt
                } else if editing {
                    attachList
                } else if store.attached.isEmpty {
                    emptyState
                } else {
                    previews
                }
            }
            if store.hasScreenAccess {
                HStack(spacing: 6) {
                    if !editing && !store.attached.isEmpty {
                        // One layout at a time: each restores its own saved frames.
                        if !store.isFilled { stripToggle }
                        if !strip.isArranged { fillToggle }
                    }
                    editToggle
                }
            }
        }
        .onAppear { store.paneVisible = true }
        .onDisappear { store.paneVisible = false }
    }

    // MARK: - Previews

    private var shown: AttachedWindow? {
        store.attached.first { $0.id == focused } ?? store.attached.first
    }

    /// The tab's order, or the strip's while it is arranged.
    private var ordered: [AttachedWindow] {
        guard strip.isArranged else { return store.attached }
        return store.attached.enumerated().sorted { a, b in
            let ia = strip.index(of: a.element.id) ?? Int.max, ib = strip.index(of: b.element.id) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let back = store.backTarget {
                    backButton(back)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ordered) { window in
                            Thumbnail(
                                window: window,
                                image: store.thumbnails[window.id],
                                isStale: store.stale.contains(window.id),
                                isFocused: window.id == shown?.id,
                                strip: stripState(of: window)
                            )
                            .offset(x: window.id == dragging ? dragX : shift(for: window))
                            .zIndex(window.id == dragging ? 1 : 0)
                            .opacity(window.id == dragging ? 0.85 : 1)
                            .gesture(reorder(window), including: strip.index(of: window.id) != nil ? .all : .subviews)
                            .onHover { inside in
                                if inside {
                                    focused = window.id
                                    store.hovered = window.id
                                }
                            }
                            .onTapGesture { store.open(window) }
                        }
                    }
                }
                .padding(.trailing, 58)
            }
            if let window = shown {
                LargePreview(
                    window: window,
                    image: store.largePreview?.id == window.id
                        ? store.largePreview?.image
                        : store.thumbnails[window.id],
                    isStale: store.stale.contains(window.id)
                )
                .onHover { inside in store.hovered = inside ? window.id : nil }
                .onTapGesture { store.open(window) }
            }
            if strip.isArranged || strip.note != nil || !strip.leftOut.isEmpty {
                stripStatus
            }
            if let note = store.fillNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            if !WindowFocus.hasAccess {
                HStack(spacing: 6) {
                    Text("Allow Accessibility so a click brings up that exact window")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                    Button(localized("Allow")) { WindowFocus.requestAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func backButton(_ app: NSRunningApplication) -> some View {
        Button {
            store.goBack()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
                Text(app.localizedName ?? localized("Back"))
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: Thumbnail.height + 16)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceHover))
        }
        .buttonStyle(.plain)
        .help(localized("Back to %@", app.localizedName ?? ""))
    }

    // MARK: - Attach list

    /// Windows grouped by app. The app row attaches every window it has now
    /// and later; a window row attaches or detaches just that one.
    private var attachList: some View {
        let groups = Dictionary(grouping: store.candidates, by: \.bundleID)
            .sorted { ($0.value.first?.appName ?? "") < ($1.value.first?.appName ?? "") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Attach windows")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.key) { group in
                        let bundleID = group.key
                        let windows = group.value
                        checkRow(
                            title: localized("All %@ windows", windows.first?.appName ?? bundleID),
                            isOn: store.isAppAttached(bundleID),
                            bold: true
                        ) { store.toggleApp(bundleID) }
                        ForEach(windows) { window in
                            checkRow(title: window.label, isOn: store.isAttached(window), bold: false) {
                                store.toggle(window)
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
                .padding(.trailing, 70)
            }
        }
        .padding(.top, 4)
    }

    private func checkRow(title: String, isOn: Bool, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? .white : Theme.tertiary)
                Text(title)
                    .font(.system(size: 12, weight: bold ? .medium : .regular))
                    .foregroundStyle(bold ? .white : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Strip

    /// One preview plus the gap after it.
    private static let slot = Thumbnail.width + 8

    /// Dragging a preview sideways moves its window along the strip. The
    /// others step aside as it passes, so the drop place is visible.
    private func reorder(_ window: AttachedWindow) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragging == nil { dragging = window.id }
                guard dragging == window.id else { return }
                withAnimation(.easeOut(duration: 0.12)) { dragX = value.translation.width }
            }
            .onEnded { value in
                defer {
                    dragging = nil
                    dragX = 0
                }
                guard let from = strip.index(of: window.id) else { return }
                let to = StripLayout.dropIndex(
                    from: from, translation: value.translation.width, slot: Self.slot, count: strip.columns.count
                )
                strip.move(window.id, to: to)
            }
    }

    /// How far a preview steps aside for the one being dragged.
    private func shift(for window: AttachedWindow) -> CGFloat {
        guard let dragged = dragging, dragged != window.id,
              let from = strip.index(of: dragged), let index = strip.index(of: window.id)
        else { return 0 }
        let to = StripLayout.dropIndex(from: from, translation: dragX, slot: Self.slot, count: strip.columns.count)
        if from < to, index > from, index <= to { return -Self.slot }
        if to < from, index >= to, index < from { return Self.slot }
        return 0
    }

    private func stripState(of window: AttachedWindow) -> Thumbnail.StripState {
        guard strip.isArranged else { return .none }
        if strip.index(of: window.id) == nil { return .out }
        return strip.inView.contains(window.id) ? .shown : .parked
    }

    /// How to move along the strip, and what was left out of it and why.
    private var stripStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            if strip.isArranged {
                Text(localized(
                    "%@ %@ or scroll over the notch to move · %@ width · drag previews to reorder",
                    strip.previousKey.label, strip.nextKey.label, strip.widthKey.label
                ))
            }
            if !strip.leftOut.isEmpty {
                Text(localized("Not in strip: %@", strip.leftOut
                    .map { "\($0.window.label) (\($0.reason.text))" }
                    .joined(separator: ", ")))
            }
            if let note = strip.note { Text(note) }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var stripToggle: some View {
        Button {
            store.toggleStrip()
        } label: {
            Image(systemName: strip.isArranged ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
                .font(.system(size: 12))
                .foregroundStyle(strip.isArranged ? Color.white : Theme.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strip.isArranged
            ? localized("Release: put the windows back where they were")
            : localized("Arrange attached windows side by side in a strip"))
    }

    private var fillToggle: some View {
        Button {
            store.toggleFill()
        } label: {
            Image(systemName: store.isFilled
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12))
                .foregroundStyle(store.isFilled ? Color.white : Theme.tertiary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(localized(store.isFilled ? "Restore window sizes" : "Fill screen with attached windows"))
    }

    private var editToggle: some View {
        Button {
            editing.toggle()
        } label: {
            if editing {
                Text(localized("Done"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceHover))
            } else {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help(localized(editing ? "Done" : "Attach windows"))
    }

    // MARK: - Empty and permission states

    private var accessPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("Preview your windows here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Needs Screen Recording. Previews stay on this Mac and are only\ntaken while this tab is open. Relaunch Cyclop after allowing it.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
            Button {
                store.requestScreenAccess()
            } label: {
                Text(localized("Allow Screen Recording"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surfaceHover))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("No windows attached")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Open the Claude app, or attach any window with the button on the right")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Thumbnail: View {
    static let width: CGFloat = 112
    static let height: CGFloat = 70
    let window: AttachedWindow
    let image: CGImage?
    let isStale: Bool
    let isFocused: Bool
    var strip: StripState = .none

    /// Where the window sits in an arranged strip.
    enum StripState { case none, shown, parked, out }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PreviewFrame(image: image, dimmed: isStale)
                .frame(width: Self.width, height: Self.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFocused ? Color.white.opacity(0.7) : Theme.hairline, lineWidth: 1)
                )
                .overlay(alignment: .bottom) { stripMark }
            Text(window.label)
                .font(.system(size: 9.5))
                .foregroundStyle(isFocused ? .white : Theme.secondary)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(localized("%@ · click to switch", window.label))
    }

    /// A bar along the bottom of the preview: bright for a window in view on
    /// the strip, faint for one parked at the screen edge.
    @ViewBuilder private var stripMark: some View {
        switch strip {
        case .shown, .parked:
            Capsule()
                .fill(strip == .shown ? Color.white.opacity(0.9) : Color.white.opacity(0.25))
                .frame(width: 28, height: 3)
                .padding(.bottom, 4)
                .accessibilityLabel(localized(strip == .shown ? "In view" : "Parked at the edge"))
        case .none, .out:
            EmptyView()
        }
    }
}

private struct LargePreview: View {
    let window: AttachedWindow
    let image: CGImage?
    let isStale: Bool

    var body: some View {
        PreviewFrame(image: image, dimmed: isStale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(window.appName)
                        .font(.system(size: 10.5, weight: .semibold))
                    if !window.title.isEmpty, window.title != window.appName {
                        Text(window.title).font(.system(size: 10.5))
                    }
                    if isStale {
                        Text("Can't capture this window now, showing last frame").font(.system(size: 10))
                    }
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(8)
            }
            .contentShape(Rectangle())
    }
}

/// A captured frame, letterboxed, or a placeholder until the first arrives.
private struct PreviewFrame: View {
    let image: CGImage?
    let dimmed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .opacity(dimmed ? 0.45 : 1)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
