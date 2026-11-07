import SwiftUI

struct RecentFilesPane: View {
    @ObservedObject var store: RecentFilesStore

    var body: some View {
        Group {
            if store.items.isEmpty {
                // Blank while the first scan is still running.
                Group {
                    if store.isLoaded { Text("Nothing recent yet") } else { Color.clear }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { file in
                            RecentFileCard(file: file, store: store)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 2)
        .onAppear {
            store.isShown = true
            store.refresh(force: true)
        }
        .onDisappear { store.isShown = false }
    }
}

private struct RecentFileCard: View {
    let file: RecentFile
    @ObservedObject var store: RecentFilesStore
    @State private var isHovered = false

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 4) {
            // Fit, not fill — a landscape screenshot and a square file icon
            // share the same box (see the shelf card).
            Image(nsImage: file.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 40)
            Text(file.name)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 24, alignment: .top)
            Text(Self.age.localizedString(for: file.date, relativeTo: Date()))
                .font(.system(size: 8))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 86, height: 106)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Theme.surfaceHover : Theme.surface)
        )
        // One click opens; a drag carries a copy out. Copies only, so a drop
        // on a Finder folder never moves a file out of Downloads.
        .overlay(
            ShelfDragSource(
                urls: { [file.url] },
                onClick: { _ in store.open(file) },
                onDoubleClick: {},
                operations: [.copy, .link]
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .help(file.url.path)
        .contextMenu {
            Button("Open") { store.open(file) }
            Button("Show in Finder") { store.reveal(file) }
        }
        .animation(Theme.contentAnimation, value: isHovered)
    }
}
