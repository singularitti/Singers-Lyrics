import SwiftUI

struct PlayerView: View {
    let song: Song

    @Environment(MusicPlaybackModel.self) private var playback
    @AppStorage(PreferenceKey.lyricSize) private var lyricSize = 44.0
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @State private var activeIndex: Int?
    @State private var autoFollow = true
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var pollingOwner = UUID()

    private var annotationSize: CGFloat { CGFloat(lyricSize * 0.6) }
    private var hasTiming: Bool { song.lines.contains { $0.timestampSeconds != nil } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let position = playback.interpolatedPosition(at: context.date)
            VStack(spacing: 0) {
                if playback.state.permissionDenied {
                    permissionBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                if let issue = playback.issue {
                    playbackIssueBanner(issue)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                lyricsScroller(position: position)

                if !hasTiming {
                    Label(
                        "No timing recorded yet — choose Sync Timing in the editor.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.blue)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                }

                Divider()
                transport(position: position)
            }
        }
        .onAppear {
            playback.startPolling(
                owner: pollingOwner,
                for: song,
                repeatsWhenFinished: true
            )
        }
        .onChange(of: song) { _, updatedSong in
            playback.startPolling(
                owner: pollingOwner,
                for: updatedSong,
                repeatsWhenFinished: true
            )
        }
        .onDisappear { playback.stopPolling(owner: pollingOwner) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerView")
    }

    private var permissionBanner: some View {
        Label(
            "Allow Singers Lyrics to control Music in System Settings › Privacy & Security › Automation.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func playbackIssueBanner(_ issue: MusicPlaybackIssue) -> some View {
        Label(issue.message, systemImage: "exclamationmark.octagon.fill")
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lyricsScroller(position: Double) -> some View {
        ScrollViewReader { proxy in
            if song.lines.allSatisfy({ $0.lyric.plainText.isEmpty }) {
                ContentUnavailableView(
                    "No Lyrics Yet",
                    systemImage: "text.quote",
                    description: Text("Switch to Edit to add and format lyrics.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(song.lines.enumerated()), id: \.element.id) { index, line in
                            lyricRow(line, index: index)
                                .id(line.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 280)
                    .padding(.horizontal, 32)
                }
                .scrollIndicators(.hidden)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking || phase == .decelerating {
                        autoFollow = false
                    }
                }
                .onChange(of: TimingUtilities.activeLineIndex(in: song.lines, position: position)) { _, next in
                    guard next != activeIndex else { return }
                    activeIndex = next
                    autoFollow = true
                    guard let next, song.lines.indices.contains(next) else { return }
                    withAnimation(.smooth(duration: 0.45)) {
                        proxy.scrollTo(song.lines[next].id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let isActive = activeIndex == index
        return Button {
            autoFollow = true
            Task {
                await playback.seekAndPlay(
                    song,
                    to: TimingUtilities.timestamp(forLineAt: index, in: song.lines)
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if !line.annotation.isEmpty {
                    Text(line.annotation)
                        .font(.system(size: annotationSize).italic())
                        .foregroundStyle(isActive ? .secondary : .tertiary)
                }
                Text(
                    AttributedTextCodec.makeSwiftUIAttributedString(
                        from: line.lyric,
                        size: CGFloat(lyricSize),
                        fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily
                    )
                )
                .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
            .scaleEffect(isActive ? 1.15 : 0.9)
            .opacity(activeIndex == nil ? 0.6 : (isActive ? 1 : 0.28))
            .animation(.smooth(duration: 0.45), value: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playerLine-\(index)")
    }

    private func transport(position: Double) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(formatTime(isScrubbing ? scrubPosition : position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : min(position, max(0, playback.state.duration)) },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(1, playback.state.duration),
                    onEditingChanged: { editing in
                        if editing {
                            scrubPosition = position
                            isScrubbing = true
                        } else {
                            let destination = scrubPosition
                            isScrubbing = false
                            Task { await playback.seekAndPlay(song, to: destination) }
                        }
                    }
                )
                .accessibilityIdentifier("playbackSlider")

                Text(formatTime(playback.state.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            HStack {
                Label(
                    nowPlayingLabel,
                    systemImage: "music.note"
                )
                .lineLimit(1)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    lyricSize = max(28, lyricSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("Smaller lyrics")

                Button {
                    lyricSize = min(72, lyricSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("Larger lyrics")

                Button {
                    Task {
                        await playback.togglePlayback(for: song)
                    }
                } label: {
                    Image(systemName: playback.isPlaying(song) ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(playback.isPlaying(song) ? "Pause" : "Play")
                .accessibilityIdentifier("playerPlayPauseButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var nowPlayingLabel: String {
        guard !playback.state.trackName.isEmpty else {
            return song.title.isEmpty ? "Untitled" : song.title
        }
        return playback.state.trackArtist.isEmpty
            ? playback.state.trackName
            : "\(playback.state.trackName) — \(playback.state.trackArtist)"
    }
}
