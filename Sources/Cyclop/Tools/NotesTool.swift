import SwiftUI

/// The scratchpad: quick notes that survive a relaunch.
@MainActor
final class NotesTool: NotchTool {
    let id: ToolID = "notes"
    let title = localized("Notes")
    let symbol = "note.text"
    let rail = ToolRail.right
    let needsKeyboard = true

    let store = NoteStore()

    func stop() { store.flush() }

    // Leaving the notes sweeps out the blank ones: they cost one hover to
    // recreate, and a trail of empty cards is clutter a scratchpad avoids.
    func didLeave() { store.leave() }

    func headerAccessory() -> AnyView { AnyView(Counter(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(NotesPane(notes: store, privacy: context.privacy, wantsKeyboard: context.wantsKeyboard))
    }

    private struct Counter: View {
        @ObservedObject var store: NoteStore
        var body: some View { ToolCounter(value: store.notes.count) }
    }
}
