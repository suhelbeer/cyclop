import SwiftUI

/// Now Playing for whatever the system is playing, browser tabs included.
/// Reads through a helper hosted by `/usr/bin/perl` (see
/// `Sources/CyclopMediaHelper/helper.m` for why), and falls back to
/// AppleScript for Apple Music and Spotify if that route is closed.
@MainActor
final class MusicTool: NotchTool {
    // "media" was the old tab's name in `config.json`; kept so a saved
    // on/off choice from before the registry still applies.
    let id: ToolID = "media"
    let title = localized("Music")
    let symbol = "music.note"
    let rail = ToolRail.left

    let media = MediaController()

    // The helper process runs only while the tool is switched on.
    func start() { media.start() }
    func stop() { media.stop() }
    // The position clock ticks only while a panel is open.
    func setPanelActive(_ active: Bool) { media.setActive(active) }

    func headerAccessory() -> AnyView { AnyView(Source(media: media)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(MediaPane(media: media))
    }

    private struct Source: View {
        @ObservedObject var media: MediaController
        var body: some View {
            HStack(spacing: 6) {
                if media.track != nil {
                    EqualizerBars(isAnimating: media.isPlaying)
                }
                Text(media.sourceName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}
