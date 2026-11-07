import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A file that might belong in the Recent row, before it is checked.
struct RecentCandidate: Sendable, Equatable {
    let url: URL
    let date: Date
}

struct RecentFile: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    /// When it was downloaded, screenshotted or last opened — whichever is newest.
    let date: Date
    /// File-type icon first, a real preview once QuickLook renders one.
    var icon: NSImage
    var name: String { url.lastPathComponent }

    static func == (lhs: RecentFile, rhs: RecentFile) -> Bool {
        lhs.url == rhs.url && lhs.date == rhs.date
    }
}

/// The rules that decide what is worth listing, free of any state so they can
/// be tested.
enum RecentFiles {
    /// How many cards the row keeps.
    static let limit = 24
    /// How far back "recently opened" and screenshots look.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Names a browser or downloader gives a file that is still arriving.
    private static let partial: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload", "tmp", "aria2",
    ]

    /// Things that were "used" without anyone meaning to: dotfiles, caches,
    /// the contents of an app bundle, half-finished downloads, apps.
    static func isNoise(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let name = url.lastPathComponent
        if name.isEmpty || name.hasPrefix(".") { return true }
        // Any hidden folder on the way (.Trash, .git, .cache, .config…).
        if url.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") }) { return true }
        let ext = url.pathExtension.lowercased()
        if partial.contains(ext) || ext == "app" { return true }
        if url.path.contains(".app/") { return true }
        if url.path.hasPrefix(home + "/Library/") { return true }
        return false
    }

    /// One entry per file (the newest date wins), newest first.
    static func merge(_ candidates: [RecentCandidate]) -> [RecentCandidate] {
        var newest: [String: RecentCandidate] = [:]
        for candidate in candidates {
            let key = candidate.url.standardizedFileURL.path
            if let existing = newest[key], existing.date >= candidate.date { continue }
            newest[key] = candidate
        }
        return newest.values.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.url.path < $1.url.path
        }
    }

    /// The files in one folder, dated by when they arrived there. Folders
    /// that are not documents (packages like .pages stay) are skipped.
    static func scan(folder: URL, imagesOnly: Bool) -> [RecentCandidate] {
        let keys: Set<URLResourceKey> = [
            .addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }
        let found: [RecentCandidate] = urls.compactMap { url in
            guard !isNoise(url), let values = try? url.resourceValues(forKeys: keys) else { return nil }
            if values.isDirectory == true && values.isPackage != true { return nil }
            if imagesOnly {
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) else { return nil }
            }
            guard let date = values.addedToDirectoryDate ?? values.contentModificationDate else { return nil }
            return RecentCandidate(url: url, date: date)
        }
        return Array(merge(found).prefix(limit))
    }
}

/// Recent downloads, screenshots and opened files, newest first.
///
/// Three sources, all local:
/// - the Downloads folder, read directly because Spotlight lags a new download;
/// - Spotlight, for files opened in the last two weeks and for screenshots
///   wherever they were saved;
/// - the screenshot folder the shelf watcher was already granted, if any.
///
/// Nothing here runs until the row is on screen. The first look into Downloads
/// raises a system permission prompt, and it should arrive with the row in
/// front of the person being asked, not at launch with no visible cause.
@MainActor
final class RecentFilesStore: ObservableObject {
    @Published private(set) var items: [RecentFile] = []
    /// False until the first scan finishes, so the empty state is not shown
    /// while the answer is still on its way.
    @Published private(set) var isLoaded = false

    /// Set by the pane while it is on screen.
    var isShown = false

    private var generation = 0
    private var lastRefresh = Date.distantPast
    private var folderResults: [RecentCandidate]?
    private var spotlightResults: [RecentCandidate]?
    private var query: NSMetadataQuery?
    private var finishObserver: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var previews: [String: NSImage] = [:]

    // MARK: - Refresh

    /// Looks again. Skipped if it ran a moment ago, so flicking between tools
    /// does not rescan every time.
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = Date()
        generation += 1
        let current = generation
        folderResults = nil
        spotlightResults = nil
        stopQuery()

        let folders = Self.foldersToScan()
        Task.detached(priority: .userInitiated) {
            var found: [RecentCandidate] = []
            for folder in folders {
                found += RecentFiles.scan(folder: folder.url, imagesOnly: folder.imagesOnly)
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                self.folderResults = result
                self.finishIfReady()
            }
        }
        startSpotlight(current)
    }

    func stop() {
        generation += 1
        stopQuery()
    }

    private static func foldersToScan() -> [(url: URL, imagesOnly: Bool)] {
        var folders: [(url: URL, imagesOnly: Bool)] = []
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            folders.append((downloads, false))
        }
        // Only a folder the person already handed over for the shelf's
        // screenshot watch: nothing new is asked for here.
        if UserDefaults.standard.bool(forKey: "screenshotFolderWatch.enabled"),
           let path = UserDefaults.standard.string(forKey: "screenshotFolderWatch.path") {
            folders.append((URL(fileURLWithPath: path, isDirectory: true), true))
        }
        return folders
    }

    // MARK: - Spotlight

    private func startSpotlight(_ current: Int) {
        let since = Date().addingTimeInterval(-RecentFiles.window) as NSDate
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "kMDItemLastUsedDate >= %@ OR (kMDItemIsScreenCapture == 1 AND kMDItemFSContentChangeDate >= %@)",
            since, since
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        self.query = query
        finishObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spotlightFinished(current) }
        }
        query.start()

        // Spotlight switched off or stuck: show what the folders gave.
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.generation == current,
                  self.spotlightResults == nil else { return }
            self.spotlightResults = []
            self.stopQuery()
            self.finishIfReady()
        }
    }

    private func spotlightFinished(_ current: Int) {
        guard generation == current, let query else { return }
        query.disableUpdates()
        var found: [RecentCandidate] = []
        for index in 0..<min(query.resultCount, 2000) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let changed = item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date
            let isScreenshot = (item.value(forAttribute: "kMDItemIsScreenCapture") as? NSNumber)?.intValue == 1
            let date = isScreenshot ? max(used ?? .distantPast, changed ?? .distantPast) : used
            guard let date, date > .distantPast else { continue }
            found.append(RecentCandidate(url: URL(fileURLWithPath: path), date: date))
        }
        spotlightResults = found
        stopQuery()
        finishIfReady()
    }

    private func stopQuery() {
        timeout?.cancel()
        timeout = nil
        query?.stop()
        query = nil
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        finishObserver = nil
    }

    // MARK: - Result

    private func finishIfReady() {
        guard let folderResults, let spotlightResults else { return }
        var shown: [RecentFile] = []
        let known = Dictionary(items.map { ($0.id, $0.icon) }, uniquingKeysWith: { first, _ in first })
        for candidate in RecentFiles.merge(folderResults + spotlightResults) {
            guard shown.count < RecentFiles.limit else { break }
            guard !RecentFiles.isNoise(candidate.url) else { continue }
            // Spotlight still lists files that were deleted, and folders.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue || NSWorkspace.shared.isFilePackage(atPath: candidate.url.path)
            else { continue }
            let icon = previews[Self.previewKey(candidate)]
                ?? known[candidate.url.path]
                ?? NSWorkspace.shared.icon(forFile: candidate.url.path)
            shown.append(RecentFile(url: candidate.url, date: candidate.date, icon: icon))
        }
        if shown != items { items = shown }
        isLoaded = true
        for file in shown where previews[Self.previewKey(file)] == nil { loadPreview(file) }
    }

    private static func previewKey(_ candidate: RecentCandidate) -> String {
        "\(candidate.url.path)|\(Int(candidate.date.timeIntervalSince1970))"
    }

    private static func previewKey(_ file: RecentFile) -> String {
        "\(file.url.path)|\(Int(file.date.timeIntervalSince1970))"
    }

    private func loadPreview(_ file: RecentFile) {
        let key = Self.previewKey(file)
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        // Same shape as the shelf's: Quick Look calls back on its own queue,
        // and only Sendable values may cross into the main actor.
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable [weak self] rep, _ in
            guard let rep else { return }
            let bitmap = rep.cgImage
            let size = rep.nsImage.size
            Task { @MainActor in
                guard let self else { return }
                let image = NSImage(cgImage: bitmap, size: size)
                self.previews[key] = image
                if let index = self.items.firstIndex(where: { $0.id == file.id }) {
                    self.items[index].icon = image
                }
            }
        }
    }

    // MARK: - Actions

    func open(_ file: RecentFile) {
        NSWorkspace.shared.open(file.url)
    }

    func reveal(_ file: RecentFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
}
