import SwiftUI

struct ClaudeSessionsPane: View {
    @ObservedObject var store: ClaudeSessionStore
    @State private var showingSetup = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if !store.hooksInstalled {
                    setupPrompt
                } else if showingSetup {
                    setupDetails
                } else if store.sessions.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            if store.hooksInstalled {
                setupToggle
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.sessions) { session in
                    SessionRow(session: session) { store.focus(session) }
                }
            }
            .padding(.trailing, 28)
        }
        .padding(.top, 2)
    }

    // MARK: - Setup

    private var setupPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("See your Claude Code sessions here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Cyclop adds a small hook to ~/.claude/settings.json that writes each\nsession's status to a local file. A backup of the file is kept.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
            pill(localized("Set up")) { store.installHooks() }
            errorLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code hooks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text("Sessions started before setup appear after their next prompt.\nClicking a session in Terminal or iTerm2 jumps to its tab; macOS asks\nonce for permission to control that app.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
            HStack(spacing: 8) {
                pill(localized("Reinstall")) { store.installHooks() }
                pill(localized("Remove hooks")) {
                    store.removeHooks()
                    showingSetup = false
                }
            }
            errorLine
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.trailing, 60)
    }

    private var setupToggle: some View {
        Button {
            showingSetup.toggle()
        } label: {
            if showingSetup {
                Text(localized("Done"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceHover))
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help(localized(showingSetup ? "Done" : "Setup"))
    }

    @ViewBuilder private var errorLine: some View {
        if let error = store.lastError {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("No Claude Code sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Running sessions show up after their next prompt")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.surfaceHover))
        }
        .buttonStyle(.plain)
    }
}

/// Project and status on the first line, what Claude is doing on the second.
private struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                StatusDot(status: session.status)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.project)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(statusLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(session.updated, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if let detail = session.notice ?? session.preview {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.surfaceHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverChange { hovering = $0 }
        .help(session.cwd)
    }

    private var statusLabel: String {
        switch session.status {
        case .needsYou: localized("Needs you")
        case .working: localized("Working")
        case .done: localized("Done")
        case .quiet: localized("Quiet")
        case .idle: localized("Ready")
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .needsYou: .orange
        case .working: .blue
        case .done: .green
        case .quiet, .idle: Theme.tertiary
        }
    }
}

private struct StatusDot: View {
    let status: ClaudeSession.Status
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(animates && pulse ? 0.35 : 1)
            .animation(animates ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            .onAppear { pulse = animates }
            .onChange(of: status) { pulse = animates }
    }

    private var animates: Bool { status == .needsYou || status == .working }

    private var color: Color {
        switch status {
        case .needsYou: .orange
        case .working: .blue
        case .done: .green
        case .quiet, .idle: Theme.tertiary
        }
    }
}
