import Foundation
import Observation
import OSLog

#if os(macOS)
import AppKit
#endif

struct MusicActionResult: Sendable {
    var succeeded: Bool
    var permissionDenied: Bool
    var failure: MusicPlaybackFailure? = nil
}

protocol MusicControlling: Sendable {
    func currentState() async -> MusicState
    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult
    func playPause() async -> MusicState
    func seek(to seconds: Double) async -> MusicActionResult
    func seekAndPlay(to seconds: Double) async -> MusicActionResult
    func stop() async -> MusicActionResult
    func pause() async -> MusicActionResult
}

extension MusicControlling {
    // A toggle is unsafe here: conformers must implement an explicit pause.
    func pause() async -> MusicActionResult {
        MusicActionResult(succeeded: false, permissionDenied: false)
    }
}

#if os(macOS)
actor AppleMusicController: MusicControlling {
    private static let logger = Logger(
        subsystem: JSONLibraryStore.bundleIdentifier,
        category: "MusicAutomation"
    )
    private static let stateSeparator = "\u{001E}"

    private struct ScriptResult {
        var succeeded: Bool
        var output: String
        var permissionDenied: Bool
    }

    private let stateScript = """
    set separatorCharacter to ASCII character 30
    set theState to "stopped"
    set thePos to "0"
    set theDuration to "0"
    set theName to ""
    set theArtist to ""
    set thePersistentID to ""
    if application "Music" is running then
      tell application "Music"
        set theState to (player state as text)
        try
          set thePos to (player position as text)
        end try
        try
          set theTrack to current track
          set theDuration to (duration of theTrack as text)
          set theName to (name of theTrack as text)
          set theArtist to (artist of theTrack as text)
          set thePersistentID to (persistent ID of theTrack as text)
        end try
      end tell
    end if
    theState & separatorCharacter & thePos & separatorCharacter & theDuration & separatorCharacter & theName & separatorCharacter & theArtist & separatorCharacter & thePersistentID
    """

    func currentState() async -> MusicState {
        let result = run(stateScript)
        guard result.succeeded else {
            return MusicState(permissionDenied: result.permissionDenied)
        }

        let parts = result.output.components(separatedBy: Self.stateSeparator)
        let state: PlaybackState = switch parts.first ?? "stopped" {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }
        return MusicState(
            state: state,
            position: Double(parts[safe: 1] ?? "") ?? 0,
            duration: Double(parts[safe: 2] ?? "") ?? 0,
            trackName: parts[safe: 3] ?? "",
            trackArtist: parts[safe: 4] ?? "",
            trackPersistentID: parts[safe: 5] ?? "",
            permissionDenied: false
        )
    }

    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult {
        let literal = Self.appleScriptLiteral(url.absoluteString)
        let titleLiteral = Self.appleScriptLiteral(title)
        let artistLiteral = Self.appleScriptLiteral(artist)
        let result = run(
            """
            tell application "Music"
              activate

              -- A web or universal link can open Music without changing its
              -- current track. Prefer an exact library match so Play reliably
              -- targets the linked song, then retain the URL as a fallback.
              set requestedTitle to "\(titleLiteral)"
              set requestedArtist to "\(artistLiteral)"
              if requestedTitle is not "" then
                try
                  set matchingTracks to search library playlist 1 for requestedTitle only names
                  repeat with candidateTrack in matchingTracks
                    try
                      set candidateTitle to name of candidateTrack
                      set candidateArtist to artist of candidateTrack
                      ignoring case, diacriticals, punctuation, hyphens and white space
                        set titleMatches to candidateTitle is requestedTitle
                        set artistMatches to requestedArtist is "" or candidateArtist is "" or candidateArtist contains requestedArtist or requestedArtist contains candidateArtist
                      end ignoring
                      if titleMatches and artistMatches then
                        play candidateTrack once true
                        return "library"
                      end if
                    end try
                  end repeat
                end try
              end if

              open location "\(literal)"
              return "link"
            end tell
            """
        )
        return MusicActionResult(
            succeeded: result.succeeded,
            permissionDenied: result.permissionDenied
        )
    }

    func playPause() async -> MusicState {
        let result = run(
            """
            tell application "Music"
              if player state is playing then
                pause
              else
                play current track once true
              end if
            end tell
            """
        )
        guard result.succeeded else {
            return MusicState(permissionDenied: result.permissionDenied)
        }
        return await currentState()
    }

    func seek(to seconds: Double) async -> MusicActionResult {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = run(
            "tell application \"Music\" to set player position to \(position)"
        )
        return MusicActionResult(
            succeeded: result.succeeded,
            permissionDenied: result.permissionDenied
        )
    }

    func seekAndPlay(to seconds: Double) async -> MusicActionResult {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = run(
            """
            tell application "Music"
              set player position to \(position)
              play current track once true
            end tell
            """
        )
        return MusicActionResult(
            succeeded: result.succeeded,
            permissionDenied: result.permissionDenied
        )
    }

    func stop() async -> MusicActionResult {
        let result = run("tell application \"Music\" to stop")
        return MusicActionResult(
            succeeded: result.succeeded,
            permissionDenied: result.permissionDenied
        )
    }

    func pause() async -> MusicActionResult {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            return MusicActionResult(succeeded: true, permissionDenied: false)
        }
        let result = run(
            """
            if application "Music" is running then
              tell application "Music"
                if player state is playing then pause
              end tell
            end if
            """
        )
        return MusicActionResult(
            succeeded: result.succeeded,
            permissionDenied: result.permissionDenied
        )
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func run(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else {
            return ScriptResult(succeeded: false, output: "", permissionDenied: false)
        }

        var details: NSDictionary?
        let descriptor = script.executeAndReturnError(&details)
        if let details {
            let number = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                ?? (details["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let permissionDenied = number == -1743
            if !permissionDenied {
                Self.logger.error("A Music Apple Event failed with code \(number ?? 0)")
            }
            return ScriptResult(
                succeeded: false,
                output: "",
                permissionDenied: permissionDenied
            )
        }
        return ScriptResult(
            succeeded: true,
            output: descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            permissionDenied: false
        )
    }
}
#endif

actor InertMusicController: MusicControlling {
    private let failsActions: Bool
    private var state = MusicState()

    init(failsActions: Bool = false) {
        self.failsActions = failsActions
    }

    func currentState() async -> MusicState { state }

    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult {
        guard !failsActions else {
            return MusicActionResult(succeeded: false, permissionDenied: false)
        }
        state = MusicState(
            state: .playing,
            position: 0,
            duration: 180,
            trackName: title,
            trackArtist: artist,
            trackPersistentID: url.absoluteString,
            permissionDenied: false
        )
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func playPause() async -> MusicState {
        guard !failsActions else { return MusicState() }
        state.state = state.state == .playing ? .paused : .playing
        return state
    }

    func seek(to seconds: Double) async -> MusicActionResult {
        guard !failsActions else {
            return MusicActionResult(succeeded: false, permissionDenied: false)
        }
        state.position = seconds.isFinite ? max(0, seconds) : 0
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func seekAndPlay(to seconds: Double) async -> MusicActionResult {
        guard !failsActions else {
            return MusicActionResult(succeeded: false, permissionDenied: false)
        }
        state.position = seconds.isFinite ? max(0, seconds) : 0
        state.state = .playing
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func stop() async -> MusicActionResult {
        guard !failsActions else {
            return MusicActionResult(succeeded: false, permissionDenied: false)
        }
        state.state = .stopped
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func pause() async -> MusicActionResult {
        guard !failsActions else {
            return MusicActionResult(succeeded: false, permissionDenied: false)
        }
        if state.state == .playing { state.state = .paused }
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }
}

enum MusicPlaybackIssue: Equatable {
    case unexpectedTrack
    case unableToStart

    var message: String {
        switch self {
        case .unexpectedTrack:
            "Music switched to another track, so playback was stopped. Press Play to restart this song."
        case .unableToStart:
            #if os(iOS)
            "Apple Music did not become ready to play this song. Try again, or open the song in Music to check its availability."
            #else
            "The linked track did not become ready in Music. Check the link, then try Play again."
            #endif
        }
    }
}

private struct PlaybackTarget: Equatable {
    var songID: UUID
    var title: String
    var artist: String
    var url: URL?

    init(song: Song) {
        let metadata = song.playbackMetadata
        songID = song.id
        title = metadata.title
        artist = metadata.artist
        url = song.appleMusicURL
    }

    func matches(_ state: MusicState) -> Bool {
        #if os(iOS)
        if state.trackPersistentID.hasPrefix("catalog:") {
            guard let expectedID = url.flatMap(ITunesTrackMetadataService.trackID(from:)),
                  state.trackPersistentID == "catalog:\(expectedID)" else {
                return false
            }
            return true
        }
        #endif
        guard Self.titleMatches(state.trackName, title) else {
            return false
        }
        return artist.isEmpty
            || state.trackArtist.isEmpty
            || Self.artistMatches(state.trackArtist, artist)
    }

    private static func titleMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let leftVariants = normalizedTitleVariants(lhs)
        let rightVariants = normalizedTitleVariants(rhs)
        return leftVariants.contains { left in
            !left.isEmpty && rightVariants.contains(left)
        }
    }

    private static func normalizedTitleVariants(_ value: String) -> [String] {
        let source = [value, removingTitleQualifier(from: value)]
        return source.flatMap { variant in
            [
                compact(variant),
                compact(variant.applyingTransform(.toLatin, reverse: false) ?? variant),
            ]
        }
    }

    private static func artistMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = compact(lhs)
        let right = compact(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right || left.contains(right) || right.contains(left) {
            return true
        }

        let leftLatin = compact(lhs.applyingTransform(.toLatin, reverse: false) ?? lhs)
        let rightLatin = compact(rhs.applyingTransform(.toLatin, reverse: false) ?? rhs)
        return !leftLatin.isEmpty
            && (leftLatin == rightLatin
                || leftLatin.contains(rightLatin)
                || rightLatin.contains(leftLatin))
    }

    private static func compact(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func removingTitleQualifier(from value: String) -> String {
        let opening: Set<Character> = ["(", "[", "{", "（", "［", "【"]
        let closing: Set<Character> = [")", "]", "}", "）", "］", "】"]
        var depth = 0
        var result = ""
        for character in value {
            if opening.contains(character) {
                depth += 1
            } else if closing.contains(character), depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }
}

struct PlaybackStartEvent: Equatable, Sendable {
    var id: UUID
    var songID: UUID
    var startedAt: Date
}

@MainActor
@Observable
final class MusicPlaybackModel {
    private struct PollingClient {
        var target: PlaybackTarget
        var repeatsWhenFinished: Bool
    }

    private let controller: any MusicControlling
    private let startupPollInterval: Duration
    private let startupMaxSamples: Int
    private let startupStableIdentitySamples: Int
    private let startupIdentityGraceSamples: Int
    private var pollingTask: Task<Void, Never>?
    private var pollingClients: [UUID: PollingClient] = [:]
    private var sampledAt = Date()
    private var target: PlaybackTarget?
    private var sessionPersistentID = ""
    private var sessionEstablished = false
    private var previousAcceptedState = MusicState()
    private var repeatsWhenFinished = false
    private var operationGeneration: UInt64 = 0
    private var activeStartupGeneration: UInt64?
    private var repeatSuppressedForVoice = false
    var beforeStartingPlayback: (@MainActor () -> Void)?

    private(set) var state = MusicState()
    private(set) var lastActionFailed = false
    private(set) var issue: MusicPlaybackIssue?
    private(set) var failure: MusicPlaybackFailure?
    private(set) var playbackStartEvent: PlaybackStartEvent?

    init(
        controller: any MusicControlling,
        startupPollInterval: Duration = .milliseconds(250),
        startupMaxSamples: Int = 48,
        startupStableIdentitySamples: Int = 4,
        startupIdentityGraceSamples: Int = 6
    ) {
        self.controller = controller
        self.startupPollInterval = startupPollInterval
        self.startupMaxSamples = max(1, startupMaxSamples)
        self.startupStableIdentitySamples = max(1, startupStableIdentitySamples)
        self.startupIdentityGraceSamples = max(1, startupIdentityGraceSamples)
    }

    func startPolling(
        owner: UUID,
        for song: Song,
        repeatsWhenFinished: Bool
    ) {
        let client = PollingClient(
            target: PlaybackTarget(song: song),
            repeatsWhenFinished: repeatsWhenFinished
        )
        pollingClients[owner] = client
        configureTarget(client.target)
        refreshRepeatPreference()

        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if activeStartupGeneration == nil {
                    await refresh()
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func stopPolling(owner: UUID) {
        pollingClients.removeValue(forKey: owner)
        guard !pollingClients.isEmpty else {
            pollingTask?.cancel()
            pollingTask = nil
            endMonitoring()
            return
        }
        if let client = pollingClients.values.first {
            configureTarget(client.target)
        }
        refreshRepeatPreference()
    }

    func beginMonitoring(_ song: Song, repeatsWhenFinished: Bool = false) {
        configureTarget(PlaybackTarget(song: song))
        self.repeatsWhenFinished = repeatsWhenFinished
    }

    func endMonitoring() {
        operationGeneration &+= 1
        activeStartupGeneration = nil
        target = nil
        sessionPersistentID = ""
        sessionEstablished = false
        repeatsWhenFinished = false
        issue = nil
        failure = nil
    }

    func interpolatedPosition(at date: Date = Date()) -> Double {
        guard state.state == .playing else { return state.position }
        return min(
            state.duration > 0 ? state.duration : .greatestFiniteMagnitude,
            state.position + max(0, date.timeIntervalSince(sampledAt))
        )
    }

    func interpolatedPosition(for song: Song, at date: Date = Date()) -> Double {
        if issue == .unexpectedTrack {
            return state.position
        }
        guard isAcceptedTargetState(state, target: PlaybackTarget(song: song)) else {
            return 0
        }
        return interpolatedPosition(at: date)
    }

    func isPlaying(_ song: Song) -> Bool {
        state.state == .playing
            && isAcceptedTargetState(state, target: PlaybackTarget(song: song))
    }

    func canSynchronize(_ song: Song) -> Bool {
        (state.state == .playing || state.state == .paused)
            && !state.permissionDenied
            && !state.actionFailed
            && !lastActionFailed
            && activeStartupGeneration == nil
            && isAcceptedTargetState(state, target: PlaybackTarget(song: song))
    }

    func play(_ song: Song, from seconds: Double = 0) async {
        prepareToStartPlayback()
        let nextTarget = PlaybackTarget(song: song)
        let mustReopenLinkedTrack = issue == .unexpectedTrack
        configureTarget(nextTarget)
        operationGeneration &+= 1
        activeStartupGeneration = nil
        let generation = operationGeneration
        issue = nil
        failure = nil
        lastActionFailed = false

        // After an unexpected album track is stopped, `state` deliberately
        // retains the selected song's last accepted position so the lyrics do
        // not jump. That cached metadata must not be mistaken for Music's
        // current track when the user presses Play again.
        if !mustReopenLinkedTrack, isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            await performSeek(to: seconds, target: nextTarget, generation: generation)
            return
        }

        guard let url = nextTarget.url else {
            issue = .unableToStart
            #if os(iOS)
            failure = MusicPlaybackFailure(reason: .invalidLink, stage: .catalog, code: "missingSongLink")
            #endif
            lastActionFailed = true
            return
        }

        activeStartupGeneration = generation
        defer {
            if activeStartupGeneration == generation {
                activeStartupGeneration = nil
            }
        }
        let stateBeforeOpen = await controller.currentState()
        guard isCurrentOperation(generation) else { return }
        if stateBeforeOpen.permissionDenied {
            state = stateBeforeOpen
            sampledAt = Date()
            lastActionFailed = true
            return
        }
        if !mustReopenLinkedTrack, nextTarget.matches(stateBeforeOpen) {
            state = stateBeforeOpen
            sampledAt = Date()
            establishSession(with: stateBeforeOpen)
            await performSeek(to: seconds, target: nextTarget, generation: generation)
            return
        }

        let opened = await controller.openTrack(
            url,
            title: nextTarget.title,
            artist: nextTarget.artist
        )
        guard isCurrentOperation(generation) else { return }
        guard opened.succeeded else {
            lastActionFailed = true
            failure = opened.failure
            if opened.permissionDenied {
                state.permissionDenied = true
            } else {
                issue = .unableToStart
            }
            return
        }

        var candidatePersistentID = ""
        var candidateSamples = 0
        var lastSample = stateBeforeOpen
        for attempt in 0..<startupMaxSamples {
            guard isCurrentOperation(generation) else { return }
            let sample = await controller.currentState()
            guard isCurrentOperation(generation) else { return }
            lastSample = sample
            if sample.permissionDenied {
                state = sample
                sampledAt = Date()
                lastActionFailed = true
                return
            }
            if nextTarget.matches(sample) {
                await acceptStartupSample(
                    sample,
                    seekTo: seconds,
                    target: nextTarget,
                    generation: generation
                )
                return
            }

            // A changed ID alone is only useful while Music has not published
            // metadata yet. Once a non-empty title is available, require it to
            // match the selected song instead of accepting an AutoPlay item.
            if sample.trackName.isEmpty,
               isChangedPersistentIdentity(sample, comparedWith: stateBeforeOpen) {
                if sample.trackPersistentID == candidatePersistentID {
                    candidateSamples += 1
                } else {
                    candidatePersistentID = sample.trackPersistentID
                    candidateSamples = 1
                }
                if candidateSamples >= startupStableIdentitySamples,
                   attempt + 1 >= startupIdentityGraceSamples {
                    await acceptStartupSample(
                        sample,
                        seekTo: seconds,
                        target: nextTarget,
                        generation: generation
                    )
                    return
                }
            } else {
                candidatePersistentID = ""
                candidateSamples = 0
            }

            if attempt < startupMaxSamples - 1 {
                try? await Task.sleep(for: startupPollInterval)
            }
        }

        guard isCurrentOperation(generation) else { return }
        await stopPlaybackStartedByFailedOpen(
            lastSample,
            stateBeforeOpen: stateBeforeOpen,
            generation: generation
        )
        guard isCurrentOperation(generation) else { return }
        issue = .unableToStart
        #if os(iOS)
        failure = MusicPlaybackFailure(reason: .request, stage: .playback, code: "trackIdentityTimeout")
        #endif
        lastActionFailed = true
    }

    private func acceptStartupSample(
        _ sample: MusicState,
        seekTo seconds: Double,
        target: PlaybackTarget,
        generation: UInt64
    ) async {
        guard isCurrentOperation(generation) else { return }
        state = sample
        sampledAt = Date()
        establishSession(with: sample)
        await performSeek(to: seconds, target: target, generation: generation)
    }

    private func isChangedPersistentIdentity(
        _ sample: MusicState,
        comparedWith previous: MusicState
    ) -> Bool {
        !sample.trackPersistentID.isEmpty
            && sample.trackPersistentID != previous.trackPersistentID
    }

    private func stopPlaybackStartedByFailedOpen(
        _ lastSample: MusicState,
        stateBeforeOpen: MusicState,
        generation: UInt64
    ) async {
        guard isCurrentOperation(generation),
              lastSample.state == .playing,
              target?.matches(lastSample) != true else {
            return
        }
        let identityChanged = isChangedPersistentIdentity(
            lastSample,
            comparedWith: stateBeforeOpen
        )
        let startedDuringOpen = stateBeforeOpen.state != .playing
        guard identityChanged || startedDuringOpen else { return }

        let result = await controller.stop()
        guard isCurrentOperation(generation) else { return }
        if result.permissionDenied {
            state.permissionDenied = true
        } else if result.succeeded {
            state.state = .stopped
        }
        sampledAt = Date()
    }

    func togglePlayback(for song: Song) async {
        prepareToStartPlayback()
        if issue == .unexpectedTrack {
            await play(song, from: 0)
            return
        }

        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)
        operationGeneration &+= 1
        activeStartupGeneration = nil
        let generation = operationGeneration
        issue = nil
        failure = nil
        lastActionFailed = false
        if isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            if state.state == .playing || state.state == .paused {
                let wasPaused = state.state == .paused
                let updatedState = await controller.playPause()
                guard isCurrentOperation(generation) else { return }
                state = updatedState
                sampledAt = Date()
                previousAcceptedState = state
                lastActionFailed = state.permissionDenied || state.actionFailed
                failure = state.failure
                if state.actionFailed {
                    issue = .unableToStart
                }
                if wasPaused, state.state == .playing, !state.permissionDenied {
                    publishPlaybackStart(for: song.id)
                }
                return
            }
            let restartPosition = state.duration > 0 && state.position >= state.duration - 1
                ? 0
                : state.position
            await performSeek(to: restartPosition, target: nextTarget, generation: generation)
            return
        }
        await play(song, from: 0)
    }

    func seekAndPlay(_ song: Song, to seconds: Double) async {
        prepareToStartPlayback()
        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)
        operationGeneration &+= 1
        activeStartupGeneration = nil
        let generation = operationGeneration
        failure = nil
        lastActionFailed = false

        if !isAcceptedTargetState(state, target: nextTarget) {
            let sample = await controller.currentState()
            guard isCurrentOperation(generation) else { return }
            state = sample
            sampledAt = Date()
        }

        if isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            await performSeek(to: seconds, target: nextTarget, generation: generation)
        } else {
            await play(song, from: seconds)
        }
    }

    func seek(_ song: Song, to seconds: Double) async {
        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)
        operationGeneration &+= 1
        activeStartupGeneration = nil
        let generation = operationGeneration
        failure = nil
        lastActionFailed = false

        if !isAcceptedTargetState(state, target: nextTarget) {
            let sample = await controller.currentState()
            guard isCurrentOperation(generation) else { return }
            sampledAt = Date()
            if sample.permissionDenied {
                state = sample
                lastActionFailed = true
                return
            }
            guard isAcceptedTargetState(sample, target: nextTarget) else { return }
            state = sample
        }

        establishSession(with: state)
        await performSeekWithoutStartingPlayback(to: seconds, generation: generation)
    }

    func refresh() async {
        let generation = operationGeneration
        let sample = await controller.currentState()
        guard isCurrentOperation(generation) else { return }
        await accept(sample, generation: generation)
    }

    private func accept(_ sample: MusicState, generation: UInt64) async {
        guard isCurrentOperation(generation) else { return }
        if sample.permissionDenied {
            state = sample
            sampledAt = Date()
            return
        }

        guard let target else {
            state = sample
            sampledAt = Date()
            return
        }

        guard sessionEstablished else {
            if target.matches(sample) {
                state = sample
                sampledAt = Date()
                establishSession(with: sample)
                if !(issue == .unableToStart && lastActionFailed) {
                    issue = nil
                }
            } else if issue != .unexpectedTrack {
                state = sample
                sampledAt = Date()
            }
            return
        }

        if isSameSessionTrack(sample, target: target) {
            if shouldRepeat(after: previousAcceptedState, current: sample) {
                beforeStartingPlayback?()
                let result = await controller.seekAndPlay(to: 0)
                guard isCurrentOperation(generation) else { return }
                lastActionFailed = !result.succeeded
                failure = result.failure
                if !result.succeeded, !result.permissionDenied { issue = .unableToStart }
                if result.permissionDenied {
                    state.permissionDenied = true
                } else if result.succeeded {
                    var restarted = sample
                    restarted.state = .playing
                    restarted.position = 0
                    state = restarted
                    previousAcceptedState = restarted
                    sampledAt = Date()
                    return
                }
            }
            state = sample
            previousAcceptedState = sample
            sampledAt = Date()
            if !(issue == .unableToStart && lastActionFailed) {
                issue = nil
            }
            return
        }

        guard !sample.trackName.isEmpty else {
            state = sample
            previousAcceptedState = sample
            sampledAt = Date()
            return
        }

        if sample.state != .stopped {
            let result = await controller.stop()
            guard isCurrentOperation(generation) else { return }
            if result.permissionDenied {
                state.permissionDenied = true
                sampledAt = Date()
                return
            }
        }

        // Freeze lyric progress at the last accepted position. Do not publish
        // the unrelated track's metadata or position into the player UI.
        state.state = .stopped
        sampledAt = Date()
        sessionPersistentID = ""
        sessionEstablished = false
        issue = .unexpectedTrack
    }

    private func performSeek(
        to seconds: Double,
        target: PlaybackTarget,
        generation: UInt64
    ) async {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = await controller.seekAndPlay(to: position)
        guard isCurrentOperation(generation) else { return }
        lastActionFailed = !result.succeeded
        failure = result.failure
        if result.permissionDenied {
            state.permissionDenied = true
            return
        }
        guard result.succeeded else {
            issue = .unableToStart
            return
        }
        state.position = position
        state.state = .playing
        sampledAt = Date()
        previousAcceptedState = state
        issue = nil
        publishPlaybackStart(for: target.songID)
    }

    private func performSeekWithoutStartingPlayback(
        to seconds: Double,
        generation: UInt64
    ) async {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = await controller.seek(to: position)
        guard isCurrentOperation(generation) else { return }
        lastActionFailed = !result.succeeded
        failure = result.failure
        if result.permissionDenied {
            state.permissionDenied = true
            return
        }
        guard result.succeeded else {
            issue = .unableToStart
            return
        }
        state.position = position
        sampledAt = Date()
        previousAcceptedState = state
        issue = nil
    }

    private func establishSession(with sample: MusicState) {
        sessionPersistentID = sample.trackPersistentID
        sessionEstablished = true
        previousAcceptedState = sample
    }

    private func publishPlaybackStart(for songID: UUID, at date: Date = Date()) {
        playbackStartEvent = PlaybackStartEvent(
            id: UUID(),
            songID: songID,
            startedAt: date
        )
    }

    private func isAcceptedTargetState(
        _ sample: MusicState,
        target nextTarget: PlaybackTarget
    ) -> Bool {
        guard issue != .unexpectedTrack else { return false }
        if sessionEstablished, target?.songID == nextTarget.songID {
            return isSameSessionTrack(sample, target: nextTarget)
        }
        return nextTarget.matches(sample)
    }

    private func isSameSessionTrack(_ sample: MusicState, target: PlaybackTarget) -> Bool {
        if !sessionPersistentID.isEmpty, !sample.trackPersistentID.isEmpty {
            return sessionPersistentID == sample.trackPersistentID
        }
        return target.matches(sample)
    }

    private func shouldRepeat(after previous: MusicState, current: MusicState) -> Bool {
        guard !repeatSuppressedForVoice else { return false }
        guard repeatsWhenFinished,
              previous.state == .playing,
              current.state == .stopped,
              previous.duration > 0 else {
            return false
        }
        return previous.position >= max(0, previous.duration - 1.5)
    }

    private func configureTarget(_ nextTarget: PlaybackTarget) {
        if target != nextTarget {
            operationGeneration &+= 1
            activeStartupGeneration = nil
            sessionPersistentID = ""
            sessionEstablished = false
            previousAcceptedState = MusicState()
            issue = nil
            failure = nil
        }
        target = nextTarget
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }

    private func refreshRepeatPreference() {
        guard let target else {
            repeatsWhenFinished = false
            return
        }
        repeatsWhenFinished = pollingClients.values.contains {
            $0.target.songID == target.songID && $0.repeatsWhenFinished
        }
    }

    func pauseForVoiceRecording() async -> Bool {
        let needsPause = state.state == .playing || activeStartupGeneration != nil
        operationGeneration &+= 1
        activeStartupGeneration = nil
        repeatSuppressedForVoice = true
        let generation = operationGeneration
        // An idle practice session needs no player request, so the Mac app
        // never asks for Automation consent just to record.
        guard needsPause else { return true }

        let result = await controller.pause()
        guard isCurrentOperation(generation) else { return false }
        lastActionFailed = !result.succeeded
        failure = result.failure
        if result.permissionDenied { state.permissionDenied = true }
        guard result.succeeded else { return false }
        if state.state == .playing { state.state = .paused }
        previousAcceptedState = state
        sampledAt = Date()
        return true
    }

    private func prepareToStartPlayback() {
        beforeStartingPlayback?()
        repeatSuppressedForVoice = false
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
