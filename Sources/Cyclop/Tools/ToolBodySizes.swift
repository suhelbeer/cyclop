/// Body sizes for the tools that are not the standard one, kept apart from
/// the tools' own files so the panel shell can be tuned without touching them.
/// A tool written later can just as well declare `bodySize` itself.

import Combine

extension MusicTool {
    /// One block of artwork and controls; anything taller is empty black.
    var bodySize: ToolBodySize { .compact }
}

extension WindowsTool {
    /// One row of previews, wide enough for several side by side. The large
    /// preview gets room only while one is pointed at (`WindowsPeek`): kept
    /// open, its box was mostly empty black around a tall window.
    var bodySize: ToolBodySize { WindowsPeek.shared.window == nil ? .wideStrip : .wide }
    var bodySizeChanges: AnyPublisher<Void, Never> { WindowsPeek.shared.changes }
}
