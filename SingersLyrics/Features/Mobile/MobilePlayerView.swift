#if os(iOS)
import SwiftUI

/// Presentation controls stay inside the detail column's bottom safe area on
/// iPad, and above the home indicator on iPhone.
struct MobilePlayerView: View {
    let song: Song
    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.lyricSize) private var lyricSize = 34.0
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
                            .onChange(of: TimingUtilities.activeLineIndex(
                                in: song.lines,
                                position: playback.interpolatedPosition(for: song, at: context.date)
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
        .accessibilityIdentifier("mobilePlayer")
    }

    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let active = activeIndex == index
        return Button {
            perform {
                await playback.seekAndPlay(song, to: TimingUtilities.timestamp(forLineAt: index, in: song.lines))
            }
        } label: {
            VStack(spacing: 6) {
                if !line.annotation.isEmpty {
                    Text(line.annotation)
                        .font(.system(size: fontSize * 0.6).italic())
                        .foregroundStyle(.secondary)
                }
                Text(AttributedTextCodec.makeSwiftUIAttributedString(
                    from: line.lyric,
                    size: fontSize,
                    fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily
                ))
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 16)
            .opacity(activeIndex == nil || !hasTiming ? 1 : (active ? 1 : 0.42))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: active)
        }
        .buttonStyle(.plain)
        .disabled(!hasTiming || isPerformingAction)
        .accessibilityLabel([line.annotation, line.lyric.plainText].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityValue(active ? "Current lyric" : "")
        .accessibilityHint(hasTiming ? "Play from this line" : "")
    }

    private func transport(position: Double) -> some View {
        VStack(spacing: 6) {
            if !hasTiming {
                Text("Add timing in Editor to follow the lyrics automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubPosition : position))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38, alignment: .leading)
                Slider(value: Binding(
                    get: { isScrubbing ? scrubPosition : min(position, max(0, playback.state.duration)) },
                    set: { scrubPosition = $0 }
                ), in: 0...max(1, playback.state.duration)) { editing in
                    if editing {
                        scrubPosition = min(position, max(0, playback.state.duration))
                        isScrubbing = true
                    } else {
                        let destination = scrubPosition
                        isScrubbing = false
                        perform { await playback.seek(song, to: destination) }
                    }
                }
                .disabled(playback.state.duration <= 0 || isPerformingAction)
                .accessibilityLabel("Playback position")
                .accessibilityValue(formatTime(isScrubbing ? scrubPosition : position))
                Text(formatTime(playback.state.duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Smaller Lyrics", systemImage: "textformat.size.smaller") {
                        lyricSize = max(24, lyricSize - 2)
                    }
                    .disabled(lyricSize <= 24)
                    Button("Larger Lyrics", systemImage: "textformat.size.larger") {
                        lyricSize = min(64, lyricSize + 2)
                    }
                    .disabled(lyricSize >= 64)
                } label: {
                    Image(systemName: "textformat.size").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Lyric text size")

                Button {
                    perform { await playback.seek(song, to: max(0, position - 15)) }
                } label: {
                    Image(systemName: "gobackward.15").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(playback.state.duration <= 0 || isPerformingAction)
                .accessibilityLabel("Back 15 seconds")

                Button {
                    perform { await playback.togglePlayback(for: song) }
                } label: {
                    ZStack {
                        if isPerformingAction {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: playback.isPlaying(song) ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.white)
                    .background(.tint, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isPerformingAction)
                .accessibilityLabel(playback.isPlaying(song) ? "Pause" : "Play")
                .accessibilityIdentifier("mobilePlayerPlayPause")

                Button {
                    perform { await playback.seek(song, to: min(playback.state.duration, position + 15)) }
                } label: {
                    Image(systemName: "goforward.15").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(playback.state.duration <= 0 || isPerformingAction)
                .accessibilityLabel("Forward 15 seconds")

                Button { followRequest = UUID() } label: {
                    Image(systemName: autoFollow ? "location.fill" : "location")
                        .frame(width: 44, height: 44)
                }
                .disabled(!hasTiming)
                .accessibilityLabel("Follow Current Lyric")
                .accessibilityValue(autoFollow ? "Following" : "Paused while scrolling")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity)
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
        follow(TimingUtilities.activeLineIndex(
            in: song.lines, position: playback.interpolatedPosition(for: song)
        ), using: proxy, force: true)
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
