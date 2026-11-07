import Foundation
import Testing
@testable import Cyclop

/// The rules for what the Recent row lists. The Spotlight query and the panel
/// are checked by eye, like the rest of the panel.
struct RecentFilesTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private func noise(_ path: String) -> Bool {
        RecentFiles.isNoise(url(path), home: "/Users/me")
    }

    @Test func ordinaryFilesAreKept() {
        #expect(!noise("/Users/me/Downloads/report.pdf"))
        #expect(!noise("/Users/me/Desktop/Screenshot 2026-11-07 at 10.00.00.png"))
        #expect(!noise("/Users/me/Documents/notes.pages"))
    }

    @Test func partialDownloadsAndHiddenThingsAreNoise() {
        #expect(noise("/Users/me/Downloads/movie.mp4.crdownload"))
        #expect(noise("/Users/me/Downloads/file.download"))
        #expect(noise("/Users/me/Downloads/.DS_Store"))
        #expect(noise("/Users/me/.config/tool/settings.json"))
        #expect(noise("/Users/me/.Trash/old.png"))
    }

    @Test func appsAndTheirInsidesAndLibraryAreNoise() {
        #expect(noise("/Applications/Safari.app"))
        #expect(noise("/Applications/Safari.app/Contents/Info.plist"))
        #expect(noise("/Users/me/Library/Caches/thing.db"))
    }

    @Test func mergeKeepsNewestPerFileAndSortsNewestFirst() {
        let now = Date()
        let merged = RecentFiles.merge([
            RecentCandidate(url: url("/a/one.png"), date: now.addingTimeInterval(-100)),
            RecentCandidate(url: url("/a/two.png"), date: now.addingTimeInterval(-50)),
            RecentCandidate(url: url("/a/one.png"), date: now),
        ])
        #expect(merged.map(\.url.lastPathComponent) == ["one.png", "two.png"])
        #expect(merged.first?.date == now)
    }

    @Test func scanDatesByArrivalSkipsFoldersAndPartials() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.png"))
        try Data("c".utf8).write(to: folder.appendingPathComponent("c.crdownload"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: false
        )

        let all = RecentFiles.scan(folder: folder, imagesOnly: false).map(\.url.lastPathComponent)
        #expect(Set(all) == ["a.txt", "b.png"])
        let images = RecentFiles.scan(folder: folder, imagesOnly: true).map(\.url.lastPathComponent)
        #expect(images == ["b.png"])
    }
}
