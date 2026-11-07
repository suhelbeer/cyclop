import AppKit
import SwiftUI

// MARK: - Dots beside the camera

/// One dot per Claude window, in the folded notch's wing left of the camera.
/// Hover one for its name and state under the notch; click it to jump to the
/// window.
struct ClaudeDots: View {
    @ObservedObject var monitor: ClaudeStatusMonitor

    /// Black between the last dot and the camera. Wider than the 6 pt the
    /// notch's own hover target reaches past its edge, so resting on the
    /// dot nearest the camera never opens the panel.
    static let inner: CGFloat = 12
    static let cell: CGFloat = 16
    /// Black before the first dot, at the outer end of the wing.
    static let outer: CGFloat = 8

    static func width(for count: Int) -> CGFloat {
        outer + CGFloat(count) * cell + inner
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
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
            Color.clear.frame(width: Self.inner)
        }
    }
}

/// A status dot: pulsing white while working, orange when something new
/// waits on you, green when finished, a ring when quiet, dim grey unknown.
struct ClaudeDot: View {
    let activity: ClaudeActivity
    var large = false

    /// Big and bright enough to read at a glance against a black menu bar:
    /// 6 pt grey rings were measured to vanish there.
    private var size: CGFloat { large ? 10 : 8 }

    var body: some View {
        Group {
            switch activity {
            case .working:
                PulsingDot()
            case .needsInput:
                Circle().fill(Color.orange)
            case .done:
                Circle().fill(Color.green)
            case .idle:
                Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
            case .unknown:
                Circle().fill(Color.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: large)
    }
}

/// The working dot's slow pulse, run by Core Animation.
///
/// A SwiftUI `repeatForever` animation re-renders the panel every frame for
/// as long as it runs, and Claude can be working for hours: measured at a
/// steady 3–5 % CPU for one 6 pt dot. A layer animation runs in the window
/// server instead and costs this process nothing between frames.
private struct PulsingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PulseView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PulseView: NSView {
        private let dot = CALayer()

        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            layer.addSublayer(dot)
            return layer
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            dot.removeAnimation(forKey: "pulse")
            guard window != nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.55
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
