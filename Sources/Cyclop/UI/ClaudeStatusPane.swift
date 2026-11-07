import SwiftUI

// MARK: - Dots beside the camera

/// One dot per Claude window, in the folded notch's wing. Hover one for its
/// name and state under the notch; click it to jump to the window.
struct ClaudeDots: View {
    @ObservedObject var monitor: ClaudeStatusMonitor

    /// Black between the camera and the first dot. Wider than the 6 pt the
    /// notch's own hover target reaches past its edge, so resting on the first
    /// dot never opens the panel.
    static let leading: CGFloat = 12
    static let cell: CGFloat = 14
    static let trailing: CGFloat = 8

    static func width(for count: Int) -> CGFloat {
        leading + CGFloat(count) * cell + trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.leading)
            ForEach(monitor.windows) { window in
                Button {
                    monitor.jump(to: window.id)
                } label: {
                    ClaudeDot(activity: window.activity, large: monitor.hovered == window.id)
                        .frame(width: Self.cell)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        monitor.hovered = window.id
                    } else if monitor.hovered == window.id {
                        monitor.hovered = nil
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A status dot: pulsing white while working, orange when something new
/// waits on you, green when finished, a ring when quiet, dim grey unknown.
struct ClaudeDot: View {
    let activity: ClaudeActivity
    var large = false
    @State private var dim = false

    private var size: CGFloat { large ? 8 : 6 }

    var body: some View {
        Group {
            switch activity {
            case .working:
                Circle().fill(Color.white)
                    .opacity(dim ? 0.3 : 1)
                    .onAppear { dim = true }
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
            case .needsInput:
                Circle().fill(Color.orange)
            case .done:
                Circle().fill(Color.green)
            case .idle:
                Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            case .unknown:
                Circle().fill(Color.white.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        // A fresh view per state, so the pulse starts over and stops cleanly.
        .id(activity)
        .animation(.easeOut(duration: 0.12), value: large)
    }
}

// MARK: - Pane

/// Every Claude window with its state; a click on a row jumps to it.
struct ClaudeStatusPane: View {
    @ObservedObject var monitor: ClaudeStatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch monitor.problem {
            case .noAccess:
                message(
                    "Needs Accessibility to read Claude's windows",
                    detail: "Cyclop only reads them; it never clicks or types into Claude.",
                    button: ("Allow…", { monitor.requestAccess() })
                )
            case .notRunning:
                message("Claude isn't running", detail: "Dots show up once the Claude app is open.", button: nil)
            case .paused, nil:
                if monitor.windows.isEmpty {
                    message(
                        monitor.problem == .paused ? "Paused while the Mac is locked" : "Looking for Claude's windows…",
                        detail: nil, button: nil
                    )
                } else {
                    rows
                }
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var rows: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(monitor.windows) { window in
                    Row(window: window, paused: monitor.problem == .paused) { monitor.jump(to: window.id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $monitor.bannersEnabled)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
            Text("Show the name when a window needs you")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            if monitor.rulesBroken {
                Text("Rules file broken, using defaults")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
            } else if monitor.problem == .paused {
                Text("Paused")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func message(_ title: LocalizedStringKey, detail: LocalizedStringKey?, button: (LocalizedStringKey, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            if let button {
                Button(action: button.1) {
                    Text(button.0)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.surfaceHover))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(.top, 4)
    }

    private struct Row: View {
        let window: ClaudeWindowStatus
        let paused: Bool
        let jump: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: jump) {
                HStack(spacing: 8) {
                    ClaudeDot(activity: window.activity)
                        .frame(width: 10)
                    Text(window.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(window.activity.label)
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                    Spacer(minLength: 0)
                    if let waiting = window.waiting, window.activity != .unknown {
                        Text(localized("%ld waiting", waiting))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? Theme.surface : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(window.matched.map { localized("Last matched: %@", $0) } ?? localized("Nothing matched on the last read"))
            .opacity(paused ? 0.6 : 1)
        }

        private var color: Color {
            switch window.activity {
            case .needsInput: .orange
            case .done: .green
            case .working: .white
            default: Theme.tertiary
            }
        }
    }
}
