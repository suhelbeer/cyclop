import AppKit
import Combine

/// Which window's large preview is down below the thumbnails, if any.
///
/// The Windows tab shows only its row of thumbnails until one is pointed at.
/// Then the large preview drops down under them, and the body grows to make
/// room. It stays while the pointer is on that thumbnail or on the preview
/// itself, with a short grace period so the trip down from one to the other,
/// across the gap and the status lines between them, does not fold it away.
@MainActor
final class WindowsPeek: ObservableObject {
    static let shared = WindowsPeek()

    @Published private(set) var window: CGWindowID?
    /// The attach list is showing in place of the previews; it needs the room.
    @Published var editing = false

    /// Long enough to cross from a thumbnail down to the preview, short
    /// enough that pointing away reads as a decision.
    private let grace: TimeInterval = 0.35
    private var pendingClear: DispatchWorkItem?

    /// The pointer is on a thumbnail or on the preview of `id`.
    func enter(_ id: CGWindowID) {
        pendingClear?.cancel()
        pendingClear = nil
        if window != id { window = id }
    }

    /// The pointer left a thumbnail or the preview.
    func leave() {
        pendingClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingClear = nil
            self?.window = nil
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    /// The pane went away: start folded next time.
    func reset() {
        pendingClear?.cancel()
        pendingClear = nil
        window = nil
        editing = false
    }

    /// Fires after anything that can change the Windows tab's height has.
    /// Coarse on purpose — the store republishes on every thumbnail refresh —
    /// and narrowed by whoever listens to the size actually changing.
    func changes(store: WindowStore) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $window.map { _ in () }.eraseToAnyPublisher(),
            $editing.map { _ in () }.eraseToAnyPublisher(),
            WindowStrip.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            store.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }
}
