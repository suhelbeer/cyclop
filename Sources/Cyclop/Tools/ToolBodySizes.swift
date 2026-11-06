/// Body sizes for the tools that are not the standard one, kept apart from
/// the tools' own files so the panel shell can be tuned without touching them.
/// A tool written later can just as well declare `bodySize` itself.

import Combine
import SwiftUI

extension MusicTool {
    /// One block of artwork and controls; anything taller is empty black.
    var bodySize: ToolBodySize { .compact }
}

extension WindowsTool {
    /// One row of previews, wide enough for several side by side. The large
    /// preview gets room only while one is pointed at (`WindowsPeek`): kept
    /// open, its box was mostly empty black around a tall window.
    var bodySize: ToolBodySize {
        let peek = WindowsPeek.shared
        if peek.editing || peek.window != nil { return .wide }
        // The "allow Screen Recording" prompt: icon, two lines and a button.
        if !store.hasScreenAccess { return .wideRow(extraHeight: 40) }
        return .wideRow(extraHeight: linesUnderRow)
    }

    var bodySizeChanges: AnyPublisher<Void, Never> {
        WindowsPeek.shared.changes(store: store)
            // Delivered on the main queue (see `changes`).
            .map { [weak self] _ in MainActor.assumeIsolated { self?.bodySize } }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Height of the status lines `WindowsPane` shows under the thumbnails,
    /// each after the stack's 10 pt gap. Mirrors the pane's conditions.
    private var linesUnderRow: CGFloat {
        let strip = WindowStrip.shared
        var height: CGFloat = 0
        var lines = 0
        if strip.isArranged { lines += 2 }
        if !strip.leftOut.isEmpty { lines += 1 }
        if strip.note != nil { lines += 1 }
        if lines > 0 { height += 10 + CGFloat(lines) * 13 + CGFloat(lines - 1) * 2 }
        if store.fillNote != nil { height += 10 + 13 }
        if !WindowFocus.hasAccess { height += 10 + 16 }
        return height
    }
}
