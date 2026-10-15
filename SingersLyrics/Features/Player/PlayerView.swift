import AppKit
import SwiftUI

enum PlayerTypography {
    static func annotationSize(for lyricSize: Double) -> CGFloat {
        CGFloat(lyricSize) * 0.5
    }

    static func titleSize(for lyricSize: Double) -> CGFloat {
        CGFloat(lyricSize) * 1.35
    }

    static func artistSize(for lyricSize: Double) -> CGFloat {
        CGFloat(lyricSize) * 0.72
    }
}

struct PlayerView: View {
    let song: Song
    let toolbarLayout: ColumnToolbarLayout

    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(LogicProRecordingModel.self) private var logicProRecording
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.lyricSize) private var lyricSize = 44.0
    @AppStorage(PreferenceKey.lyricAlignment) private var lyricAlignment = PlayerLyricAlignment.center
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @GestureState private var lyricMagnification: CGFloat?
    @State private var pinchPlaybackLock = PlayerPinchPlaybackLock()
    @State private var activeIndex: Int?
    @State private var autoFollow = true
    @State private var lastLineHeight: CGFloat = 0
    @State private var followRequest = UUID()
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var pollingOwner = UUID()

    private var displayedLyricSize: Double { magnifiedLyricSize(lyricMagnification ?? 1) }
    private var lyricSpacing: PlayerLyricSpacing { PlayerLyricSpacing(fontSize: CGFloat(displayedLyricSize)) }
    private var annotationSize: CGFloat { PlayerTypography.annotationSize(for: displayedLyricSize) }
    private var titleSize: CGFloat { PlayerTypography.titleSize(for: displayedLyricSize) }
    private var artistSize: CGFloat { PlayerTypography.artistSize(for: displayedLyricSize) }
    private var hasTiming: Bool { song.lines.contains { $0.timestampSeconds != nil } }
    private var logicProRecordingState: String {
        if logicProRecording.isRecording { return "Recording" }
        return logicProRecording.isArmed ? "On" : "Off"
    }
    private var logicProRecordingHelp: String {
        if logicProRecording.isRecording { return "Stop Recording in Logic Pro" }
        return logicProRecording.isArmed
            ? "Turn Off Recording in Logic Pro"
            : "Record in Logic Pro While the Song Plays"
    }

    var body: some View {
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

            lyricsScroller

            if !hasTiming {
                Label(
                    "No timing recorded yet — select a lyric and use the timing panel in the editor.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.blue)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                transport(position: playback.interpolatedPosition(for: song, at: context.date))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
        .onDisappear {
            playback.stopPolling(owner: pollingOwner)
            pinchPlaybackLock.reset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerView")
    }

    private var songHeader: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(song.title.isEmpty ? "Untitled" : song.title)
                .font(.system(size: titleSize, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("playerSongTitle")

            if !song.artist.isEmpty {
                Text(song.artist)
                    .font(.system(size: artistSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("playerSongArtist")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerSongHeader")
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

    private var lyricsScroller: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    // Resolve every row's height up front. Lazy height estimates
                    // otherwise correct the scroll offset as lyrics enter view.
                    VStack(spacing: 0) {
                        // Metadata scrolls with the presentation, but is deliberately
                        // outside song.lines so it never receives a timestamp or index.
                        songHeader
                            .padding(.bottom, 64)

                        if song.lines.allSatisfy({ $0.lyric.plainText.isEmpty }) {
                            ContentUnavailableView(
                                "No Lyrics Yet",
                                systemImage: "text.quote",
                                description: Text("Open the editor to add and format lyrics.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(song.lines.enumerated()), id: \.element.id) { index, line in
                                    lyricRow(line, index: index)
                                        .onGeometryChange(for: CGFloat?.self, of: { proxy in
                                            line.id == song.lines.last?.id ? proxy.size.height : nil
                                        }) { height in
                                            if let height { lastLineHeight = height }
                                        }
                                        .id(line.id)
                                }
                            }
                        }
                    }
                    .frame(minWidth: max(0, geometry.size.width - 64))
                    .padding(.top, 280)
                    // At the bottom limit, the final row's center meets the
                    // viewport's center, including after font or window resizing.
                    .padding(.bottom, max(0, (geometry.size.height - lastLineHeight) / 2))
                    .padding(.horizontal, 32)
                    .background(PlayerScrollConfiguration())
                }
                .scrollIndicators(.hidden, axes: .vertical)
                .scrollIndicators(.visible, axes: .horizontal)
                .contentShape(Rectangle())
                .simultaneousGesture(lyricSizeGesture)
                .onChange(of: lyricMagnification == nil) { _, hasEnded in
                    // GestureState also resets when a pinch is cancelled.
                    if hasEnded { pinchPlaybackLock.endPinch() }
                }
                .accessibilityHint("Pinch to resize lyrics.")
                .accessibilityAction(named: "Smaller Lyrics") { lyricSize = max(28, lyricSize - 2) }
                .accessibilityAction(named: "Larger Lyrics") { lyricSize = min(72, lyricSize + 2) }
                .accessibilityIdentifier("playerLyricsScrollView")
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                // The column toolbar blurs and fades the actual lyrics at the top.
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking || phase == .decelerating {
                        autoFollow = false
                    }
                }
                .background {
                    // Observe the playback clock without rebuilding and measuring
                    // every attributed lyric at the timeline's 30 Hz cadence.
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        Color.clear
                            .onChange(
                                of: playback.activeLyricIndex(for: song, at: context.date)
                            ) { _, next in
                                followLyricLine(next, using: proxy)
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onAppear { resumeFollowing(using: proxy) }
                .onChange(of: playback.isPlaying(song)) { _, isPlaying in
                    guard isPlaying else { return }
                    resumeFollowing(using: proxy)
                }
                .onChange(of: playback.playbackStartEvent) { _, event in
                    guard event?.songID == song.id else { return }
                    resumeFollowing(using: proxy)
                }
                .onChange(of: followRequest) { _, _ in resumeFollowing(using: proxy) }
            }
            .id(song.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Track the scroller's top so the fade never covers playback banners.
        .background(ColumnToolbarAnchor(layout: toolbarLayout, column: .player))
    }

    private func magnifiedLyricSize(_ magnification: CGFloat) -> Double {
        min(72, max(28, lyricSize * Double(magnification)))
    }

    private var lyricSizeGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .updating($lyricMagnification) { value, magnification, transaction in
                transaction.animation = nil
                magnification = value.magnification
            }
            .onChanged { _ in pinchPlaybackLock.beginPinch() }
            .onEnded { value in
                withTransaction(Transaction(animation: nil)) {
                    lyricSize = magnifiedLyricSize(value.magnification)
                }
                pinchPlaybackLock.endPinch()
            }
    }

    private func resumeFollowing(using proxy: ScrollViewProxy) {
        followLyricLine(
            playback.activeLyricIndex(for: song),
            force: true,
            using: proxy
        )
    }

    private func followLyricLine(
        _ next: Int?,
        force: Bool = false,
        using proxy: ScrollViewProxy
    ) {
        guard force || next != activeIndex else { return }
        activeIndex = next
        if force { autoFollow = true }
        guard autoFollow, let next, song.lines.indices.contains(next) else { return }
        var transaction = Transaction(animation: reduceMotion ? nil : PlayerLyricEmphasis.motionAnimation)
        transaction.isContinuous = true
        withTransaction(transaction) {
            proxy.scrollTo(song.lines[next].id, anchor: .center)
        }
    }

    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let isActive = activeIndex == index
        let emphasisScale: CGFloat = reduceMotion ? 1 : PlayerLyricEmphasis.scale(isActive: isActive)
        return Button {
            guard !pinchPlaybackLock.isLocked else { return }
            Task {
                guard !pinchPlaybackLock.isLocked else { return }
                await playback.seekAndPlay(
                    song,
                    to: TimingUtilities.timestamp(forLineAt: index, in: song.lines)
                )
                logicProRecording.startRecording(songID: song.id, isPlaying: playback.isPlaying(song))
            }
        } label: {
            PlayerLyricScaleLayout(
                maximumScale: PlayerLyricEmphasis.activeScale,
                anchor: lyricAlignment.scaleAnchor
            ) {
                PlayerLyricBlockLayout(spacing: 4) {
                    if !line.annotation.isEmpty {
                        Text(line.annotation)
                            .font(.system(size: annotationSize).italic())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(
                        AttributedTextCodec.makeSwiftUIAttributedString(
                            from: line.lyric,
                            size: CGFloat(displayedLyricSize),
                            fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily
                        )
                    )
                    .lineSpacing(lyricSpacing.wrappedLineSpacing)
                    .multilineTextAlignment(lyricAlignment.textAlignment)
                    .fixedSize(horizontal: true, vertical: true)
                }
                .fixedSize(horizontal: true, vertical: true)
                .scaleEffect(emphasisScale, anchor: lyricAlignment.scaleAnchor)
                .animation(reduceMotion ? nil : PlayerLyricEmphasis.motionAnimation, value: isActive)
            }
            .frame(maxWidth: .infinity, alignment: lyricAlignment.frameAlignment)
            .padding(.vertical, lyricSpacing.rowPadding)
            .opacity(PlayerLyricEmphasis.opacity(isActive: isActive))
            .animation(reduceMotion ? nil : PlayerLyricEmphasis.highlightAnimation, value: isActive)
        }
        .buttonStyle(.plain)
        .disabled(pinchPlaybackLock.isLocked)
        .accessibilityIdentifier("playerLine-\(index)")
    }

    private func transport(position: Double) -> some View {
        let duration = playback.duration(for: song)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(formatPlaybackTime(duration == nil ? nil : (isScrubbing ? scrubPosition : position)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                    .fixedSize()

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : min(position, duration ?? 0) },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(1, duration ?? 0),
                    onEditingChanged: { editing in
                        if editing {
                            scrubPosition = position
                            isScrubbing = true
                        } else {
                            let destination = scrubPosition
                            isScrubbing = false
                            Task {
                                await playback.seek(song, to: destination)
                                followRequest = UUID()
                            }
                        }
                    }
                )
                .frame(minWidth: 72)
                .layoutPriority(1)
                .accessibilityIdentifier("playbackSlider")

                Text(formatPlaybackTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                PlayerLyricAlignmentControls(selection: $lyricAlignment)

                Button {
                    if logicProRecording.isArmed {
                        logicProRecording.setArmed(false)
                    } else {
                        logicProRecording.setArmed(true)
                        // Mid-song, the take starts now; otherwise the next Play starts it.
                        logicProRecording.startRecording(songID: song.id, isPlaying: playback.isPlaying(song))
                    }
                } label: {
                    Image(systemName: logicProRecording.isRecording ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(logicProRecording.isArmed ? Color.red : Color.primary)
                        .symbolEffect(.pulse, isActive: logicProRecording.isRecording)
                }
                .help(logicProRecordingHelp)
                .accessibilityLabel("Record in Logic Pro")
                .accessibilityValue(logicProRecordingState)
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("logicProRecordingButton")

                Button {
                    followRequest = UUID()
                } label: {
                    Image(systemName: autoFollow ? "location.fill" : "location")
                }
                .disabled(!hasTiming)
                .help("Follow Current Lyric")
                .accessibilityLabel("Follow Current Lyric")
                .accessibilityValue(autoFollow ? "Following" : "Paused while scrolling")
                .accessibilityIdentifier("followCurrentLyricButton")

                Button {
                    Task {
                        await playback.togglePlayback(for: song)
                        logicProRecording.startRecording(songID: song.id, isPlaying: playback.isPlaying(song))
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
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerTransport")
    }
}

/// Keep the lyrics' bottom limit firm without changing scrolling in the editor.
private struct PlayerScrollConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.configureScrollView()
    }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollView()
        }

        override func layout() {
            super.layout()
            configureScrollView()
        }

        func configureScrollView() {
            enclosingScrollView?.verticalScrollElasticity = .none
        }
    }
}
