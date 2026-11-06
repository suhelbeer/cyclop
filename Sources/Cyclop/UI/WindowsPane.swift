import SwiftUI

/// A strip of small live previews on top, one large preview below. The large
/// one follows the pointer over the strip and stays on the last window
/// pointed at, so moving down onto it to click does not swap it out.
struct WindowsPane: View {
    @ObservedObject var store: WindowStore
    @State private var editing = false
    /// The window in the large preview.
    @State private var focused: CGWindowID?

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
            if store.hasScreenAccess { editToggle }
        }
        .onAppear { store.paneVisible = true }
        .onDisappear { store.paneVisible = false }
    }

    // MARK: - Previews

    private var shown: AttachedWindow? {
        store.attached.first { $0.id == focused } ?? store.attached.first
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let back = store.backTarget {
                    backButton(back)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attached) { window in
                            Thumbnail(
                                window: window,
                                image: store.thumbnails[window.id],
                                isFocused: window.id == shown?.id
                            )
                            .onHover { inside in
                                if inside {
                                    focused = window.id
                                    store.hovered = window.id
                                }
                            }
                            .onTapGesture { store.jump(to: window) }
                        }
                    }
                }
                .padding(.trailing, 30)
            }
            if let window = shown {
                LargePreview(
                    window: window,
                    image: store.largePreview?.id == window.id
                        ? store.largePreview?.image
                        : store.thumbnails[window.id]
                )
                .onHover { inside in store.hovered = inside ? window.id : nil }
                .onTapGesture { store.jump(to: window) }
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
    static let height: CGFloat = 70
    let window: AttachedWindow
    let image: CGImage?
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PreviewFrame(image: image, dimmed: !window.isOnScreen)
                .frame(width: 112, height: Self.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFocused ? Color.white.opacity(0.7) : Theme.hairline, lineWidth: 1)
                )
            Text(window.label)
                .font(.system(size: 9.5))
                .foregroundStyle(isFocused ? .white : Theme.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(localized("%@ · click to switch", window.label))
    }
}

private struct LargePreview: View {
    let window: AttachedWindow
    let image: CGImage?

    var body: some View {
        PreviewFrame(image: image, dimmed: !window.isOnScreen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(window.appName)
                        .font(.system(size: 10.5, weight: .semibold))
                    if !window.title.isEmpty, window.title != window.appName {
                        Text(window.title).font(.system(size: 10.5))
                    }
                    if !window.isOnScreen {
                        Text("Not visible, showing last frame").font(.system(size: 10))
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
