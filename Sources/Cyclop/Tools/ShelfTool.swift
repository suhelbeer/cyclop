import SwiftUI

@MainActor
final class ShelfTool: NotchTool {
    let id: ToolID = "shelf"
    let title = localized("Shelf")
    let symbol = "tray.full.fill"
    let rail = ToolRail.left
    let acceptsFileDrops = true

    let store = ShelfStore()
    let screenshotFolder = ScreenshotFolderWatcher()

    init() { store.load() }

    func start() {
        // Off until the user grants a folder in Settings; this only re-arms a
        // watch approved on a previous launch.
        screenshotFolder.resumeIfEnabled()
    }
    func stop() { screenshotFolder.stop() }
    func didEnter() { store.refreshFromDisk() }

    func acceptDrop(_ urls: [URL]) -> Bool {
        store.add(urls)
        return true
    }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(ShelfPane(shelf: store, isTargeted: context.isDropTargeted))
    }

    private struct Counter: View {
        @ObservedObject var store: ShelfStore
        var body: some View { ToolCounter(value: store.items.count) }
    }
}
