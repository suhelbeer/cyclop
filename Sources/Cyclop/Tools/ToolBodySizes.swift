/// Body sizes for the tools that are not the standard one, kept apart from
/// the tools' own files so the panel shell can be tuned without touching them.
/// A tool written later can just as well declare `bodySize` itself.

extension MusicTool {
    /// One block of artwork and controls; anything taller is empty black.
    var bodySize: ToolBodySize { .compact }
}

extension WindowsTool {
    /// Room for more previews side by side.
    var bodySize: ToolBodySize { .wide }
}
