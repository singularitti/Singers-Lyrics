#if os(iOS)
import SwiftUI

/// Presentation controls stay inside the detail column's bottom safe area on
/// iPad, and above the home indicator on iPhone.
struct MobilePlayerView: View {
    let song: Song
    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.lyricSize) private var lyricSize = 34.0
    @AppStorage(PreferenceKey.lyricAlignment) private var lyricAlignment = PlayerLyricAlignment.center
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @ScaledMetric(relativeTo: .title) private var typeScale = 1.0
    @State private var activeIndex: Int?
    @State private var autoFollow = true
    @State private var followRequest = UUID()
    @State private var lastLineHeight: CGFloat = 0
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var isPerformingAction = false

    private var fontSize: CGFloat { CGFloat(lyricSize * typeScale) }
    private var hasTiming: Bool { song.lines.contains { $0.timestampSeconds != nil } }

    private enum ControlMetrics {
        static let spacing: CGFloat = 8
        static let textSizeButtonWidth: CGFloat = 32
        static let utilityButtonWidth: CGFloat = 44
        static let playButtonSize: CGFloat = 60
        static let playbackWidth = utilityButtonWidth * 2 + playButtonSize + spacing * 2
        static let presentationWidth = textSizeButtonWidth * 2 + spacing
            + utilityButtonWidth * CGFloat(PlayerLyricAlignment.allCases.count)
        static let rowWidth = presentationWidth + playbackWidth + utilityButtonWidth + spacing * 2
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                            Text(song.title.isEmpty ? "Untitled" : song.title)
                                .font(.system(size: fontSize * 1.3, weight: .bold))
                                .accessibilityAddTraits(.isHeader)
                            if !song.artist.isEmpty {
                                Text(song.artist)
                                    .font(.system(size: fontSize * 0.65, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 48)

                        if song.lines.allSatisfy({ $0.lyric.plainText.isEmpty }) {
                            ContentUnavailableView("No Lyrics Yet", systemImage: "text.quote",
                                description: Text("Switch to Editor to add your lyrics."))
                        } else {
                            ForEach(Array(song.lines.enumerated()), id: \.element.id) { index, line in
                                lyricRow(line, index: index)
                                    .id(line.id)
                                    .onGeometryChange(for: CGFloat?.self, of: { row in
                                        line.id == song.lines.last?.id ? row.size.height : nil
                                    }) { height in
                                        if let height { lastLineHeight = height }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, min(geometry.size.height * 0.22, 140))
                    .padding(.bottom, max(24, (geometry.size.height - lastLineHeight) / 2))
                    .frame(maxWidth: 850)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        autoFollow = false
                    }
                }
                .background {
                    TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                        Color.clear
                            .onChange(of: playback.activeLyricIndex(
                                for: song,
                                at: context.date
                            )) { _, index in follow(index, using: proxy) }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onAppear { resumeFollowing(using: proxy) }
                .onChange(of: followRequest) { _, _ in resumeFollowing(using: proxy) }
                .onChange(of: playback.playbackStartEvent) { _, event in
                    if event?.songID == song.id { resumeFollowing(using: proxy) }
                }
                .onChange(of: playback.isPlaying(song)) { _, playing in
                    if playing { resumeFollowing(using: proxy) }
                }
                .accessibilityIdentifier("mobilePlayerLyrics")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                transport(position: playback.interpolatedPosition(for: song, at: context.date))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(uiColor: .systemBackground))
        .keepsScreenAwake(playback.isPlaying(song))
        .accessibilityIdentifier("mobilePlayer")
    }

    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let active = activeIndex == index
        return Button {
            perform {
                await playback.seekAndPlay(song, to: TimingUtilities.timestamp(forLineAt: index, in: song.lines))
            }
        } label: {
            PlayerLyricBlockLayout(spacing: 6) {
                if !line.annotation.isEmpty {
                    Text(line.annotation)
                        .font(.system(size: fontSize * 0.6).italic())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Text(AttributedTextCodec.makeSwiftUIAttributedString(
                    from: line.lyric,
                    size: fontSize,
                    fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily
                ))
                .multilineTextAlignment(lyricAlignment.textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: lyricAlignment.frameAlignment)
            .padding(.vertical, 16)
            .opacity(PlayerLyricEmphasis.opacity(isActive: active))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: active)
        }
        .buttonStyle(.plain)
        .disabled(!hasTiming || isPerformingAction)
        .accessibilityLabel([line.annotation, line.lyric.plainText].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityValue(active ? "Current lyric" : "")
        .accessibilityHint(hasTiming ? "Play from this line" : "")
    }

    private func transport(position: Double) -> some View {
        let duration = playback.duration(for: song)
        let shownPosition = duration == nil ? nil : (isScrubbing ? scrubPosition : position)
        return VStack(spacing: 6) {
            if !hasTiming {
                Text("Add timing in Editor to follow the lyrics automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Text(formatPlaybackTime(shownPosition))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38, alignment: .leading)
                Slider(value: Binding(
                    get: { isScrubbing ? scrubPosition : min(position, duration ?? 0) },
                    set: { scrubPosition = $0 }
                ), in: 0...max(1, duration ?? 0)) { editing in
                    if editing {
                        scrubPosition = min(position, duration ?? 0)
                        isScrubbing = true
                    } else {
                        let destination = scrubPosition
                        isScrubbing = false
                        perform { await playback.seek(song, to: destination) }
                    }
                }
                .disabled(duration == nil || isPerformingAction)
                .accessibilityLabel("Playback position")
                .accessibilityValue(formatPlaybackTime(shownPosition))
                Text(formatPlaybackTime(duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38, alignment: .trailing)
            }
            ViewThatFits(in: .horizontal) {
                widePlayerControls(position: position, duration: duration)
                stackedPlayerControls(position: position, duration: duration)
            }
        }
        // Fit one complete button row plus padding, regardless of orientation or sidebar state.
        .frame(maxWidth: ControlMetrics.rowWidth)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity)
    }

    private func widePlayerControls(position: Double, duration: Double?) -> some View {
        HStack(spacing: ControlMetrics.spacing) {
            presentationControls

            playbackButtons(position: position, duration: duration)
                .frame(width: ControlMetrics.playbackWidth)

            followButton
        }
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.plain)
        .font(.system(size: 17))
    }

    private func stackedPlayerControls(position: Double, duration: Double?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: ControlMetrics.spacing) {
                presentationControls

                Spacer(minLength: 0)

                followButton
            }

            playbackButtons(position: position, duration: duration)
                .frame(width: 200)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
    }

    private var presentationControls: some View {
        HStack(spacing: ControlMetrics.spacing) {
            textSizeControls
            PlayerLyricAlignmentControls(
                selection: $lyricAlignment,
                spacing: 0,
                buttonWidth: ControlMetrics.utilityButtonWidth
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var textSizeControls: some View {
        HStack(spacing: 0) {
            Button { lyricSize = max(24, lyricSize - 2) } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: ControlMetrics.textSizeButtonWidth, height: ControlMetrics.utilityButtonWidth)
                    .contentShape(Rectangle())
            }
            .disabled(lyricSize <= 24)
            .accessibilityLabel("Smaller Lyrics")

            Button { lyricSize = min(64, lyricSize + 2) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: ControlMetrics.textSizeButtonWidth, height: ControlMetrics.utilityButtonWidth)
                    .contentShape(Rectangle())
            }
            .disabled(lyricSize >= 64)
            .accessibilityLabel("Larger Lyrics")
        }
    }

    private var followButton: some View {
        Button { followRequest = UUID() } label: {
            Image(systemName: autoFollow ? "location.fill" : "location")
                .frame(width: ControlMetrics.utilityButtonWidth, height: ControlMetrics.utilityButtonWidth)
                .contentShape(Rectangle())
        }
        .disabled(!hasTiming)
        .accessibilityLabel("Follow Current Lyric")
        .accessibilityValue(autoFollow ? "Following" : "Paused while scrolling")
    }

    private func playbackButtons(position: Double, duration: Double?) -> some View {
        HStack(spacing: 0) {
            Button {
                perform { await playback.seek(song, to: max(0, position - 5)) }
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 22))
                    .frame(width: ControlMetrics.utilityButtonWidth, height: ControlMetrics.utilityButtonWidth)
                    .contentShape(Rectangle())
            }
            .disabled(duration == nil || isPerformingAction)
            .accessibilityLabel("Back 5 seconds")

            Spacer(minLength: ControlMetrics.spacing)

            Button {
                perform { await playback.togglePlayback(for: song) }
            } label: {
                ZStack {
                    if isPerformingAction {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: playback.isPlaying(song) ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                    }
                }
                .frame(width: ControlMetrics.playButtonSize, height: ControlMetrics.playButtonSize)
                .foregroundStyle(.white)
                .background(.tint, in: Circle())
            }
            .disabled(isPerformingAction)
            .accessibilityLabel(playback.isPlaying(song) ? "Pause" : "Play")
            .accessibilityIdentifier("mobilePlayerPlayPause")

            Spacer(minLength: ControlMetrics.spacing)

            Button {
                perform { await playback.seek(song, to: min(duration ?? 0, position + 5)) }
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 22))
                    .frame(width: ControlMetrics.utilityButtonWidth, height: ControlMetrics.utilityButtonWidth)
                    .contentShape(Rectangle())
            }
            .disabled(duration == nil || isPerformingAction)
            .accessibilityLabel("Forward 5 seconds")
        }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            await action()
            followRequest = UUID()
        }
    }

    private func resumeFollowing(using proxy: ScrollViewProxy) {
        autoFollow = true
        follow(playback.activeLyricIndex(for: song), using: proxy, force: true)
    }

    private func follow(_ index: Int?, using proxy: ScrollViewProxy, force: Bool = false) {
        guard force || index != activeIndex else { return }
        activeIndex = index
        guard autoFollow, let index, song.lines.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            proxy.scrollTo(song.lines[index].id, anchor: .center)
        }
    }
}
#endif
