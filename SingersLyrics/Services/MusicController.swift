import AppKit
import Foundation
import Observation
import OSLog

struct MusicActionResult: Sendable {
    var succeeded: Bool
    var permissionDenied: Bool
}

protocol MusicControlling: Sendable {
    func currentState() async -> MusicState
    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult
    func playPause() async -> MusicState
    func seek(to seconds: Double) async -> MusicActionResult
    func seekAndPlay(to seconds: Double) async -> MusicActionResult
    func stop() async -> MusicActionResult
}

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

actor InertMusicController: MusicControlling {
    func currentState() async -> MusicState { MusicState() }
    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult {
        MusicActionResult(succeeded: true, permissionDenied: false)
    }
    func playPause() async -> MusicState { MusicState() }
    func seek(to seconds: Double) async -> MusicActionResult {
        MusicActionResult(succeeded: true, permissionDenied: false)
    }
    func seekAndPlay(to seconds: Double) async -> MusicActionResult {
        MusicActionResult(succeeded: true, permissionDenied: false)
    }
    func stop() async -> MusicActionResult {
        MusicActionResult(succeeded: true, permissionDenied: false)
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
            "The linked track did not become ready in Music. Check the link, then try Play again."
        }
    }
}

private struct PlaybackTarget: Equatable {
    var songID: UUID
    var title: String
    var artist: String
    var url: URL?

    init(song: Song) {
        songID = song.id
        title = song.title
        artist = song.artist
        url = song.appleMusicURL
    }

    func matches(_ state: MusicState) -> Bool {
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
    private var isStartingTrack = false

    private(set) var state = MusicState()
    private(set) var lastActionFailed = false
    private(set) var issue: MusicPlaybackIssue?

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
                if !isStartingTrack {
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
        target = nil
        sessionPersistentID = ""
        sessionEstablished = false
        repeatsWhenFinished = false
        issue = nil
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

    func play(_ song: Song, from seconds: Double = 0) async {
        let nextTarget = PlaybackTarget(song: song)
        let mustReopenLinkedTrack = issue == .unexpectedTrack
        configureTarget(nextTarget)
        issue = nil
        lastActionFailed = false

        // After an unexpected album track is stopped, `state` deliberately
        // retains the selected song's last accepted position so the lyrics do
        // not jump. That cached metadata must not be mistaken for Music's
        // current track when the user presses Play again.
        if !mustReopenLinkedTrack, isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            await performSeek(to: seconds)
            return
        }

        guard let url = nextTarget.url else {
            issue = .unableToStart
            lastActionFailed = true
            return
        }

        isStartingTrack = true
        defer { isStartingTrack = false }
        let stateBeforeOpen = await controller.currentState()
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
            await performSeek(to: seconds)
            return
        }

        let opened = await controller.openTrack(
            url,
            title: nextTarget.title,
            artist: nextTarget.artist
        )
        guard opened.succeeded else {
            lastActionFailed = true
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
            let sample = await controller.currentState()
            lastSample = sample
            if sample.permissionDenied {
                state = sample
                sampledAt = Date()
                lastActionFailed = true
                return
            }
            if nextTarget.matches(sample) {
                await acceptStartupSample(sample, seekTo: seconds)
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
                    await acceptStartupSample(sample, seekTo: seconds)
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

        await stopPlaybackStartedByFailedOpen(lastSample, stateBeforeOpen: stateBeforeOpen)
        issue = .unableToStart
        lastActionFailed = true
    }

    private func acceptStartupSample(_ sample: MusicState, seekTo seconds: Double) async {
        state = sample
        sampledAt = Date()
        establishSession(with: sample)
        await performSeek(to: seconds)
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
        stateBeforeOpen: MusicState
    ) async {
        guard lastSample.state == .playing,
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
        if result.permissionDenied {
            state.permissionDenied = true
        } else if result.succeeded {
            state.state = .stopped
        }
        sampledAt = Date()
    }

    func togglePlayback(for song: Song) async {
        if issue == .unexpectedTrack {
            await play(song, from: 0)
            return
        }

        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)
        if isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            if state.state == .playing || state.state == .paused {
                state = await controller.playPause()
                sampledAt = Date()
                previousAcceptedState = state
                lastActionFailed = state.permissionDenied
                return
            }
            let restartPosition = state.duration > 0 && state.position >= state.duration - 1
                ? 0
                : state.position
            await performSeek(to: restartPosition)
            return
        }
        await play(song, from: 0)
    }

    func seekAndPlay(_ song: Song, to seconds: Double) async {
        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)

        if !isAcceptedTargetState(state, target: nextTarget) {
            let sample = await controller.currentState()
            state = sample
            sampledAt = Date()
        }

        if isAcceptedTargetState(state, target: nextTarget) {
            establishSession(with: state)
            await performSeek(to: seconds)
        } else {
            await play(song, from: seconds)
        }
    }

    func seek(_ song: Song, to seconds: Double) async {
        let nextTarget = PlaybackTarget(song: song)
        configureTarget(nextTarget)

        if !isAcceptedTargetState(state, target: nextTarget) {
            let sample = await controller.currentState()
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
        await performSeekWithoutStartingPlayback(to: seconds)
    }

    func refresh() async {
        let sample = await controller.currentState()
        await accept(sample)
    }

    private func accept(_ sample: MusicState) async {
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
                issue = nil
            } else if issue != .unexpectedTrack {
                state = sample
                sampledAt = Date()
            }
            return
        }

        if isSameSessionTrack(sample, target: target) {
            if shouldRepeat(after: previousAcceptedState, current: sample) {
                let result = await controller.seekAndPlay(to: 0)
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
            issue = nil
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

    private func performSeek(to seconds: Double) async {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = await controller.seekAndPlay(to: position)
        lastActionFailed = !result.succeeded
        if result.permissionDenied {
            state.permissionDenied = true
            return
        }
        guard result.succeeded else { return }
        state.position = position
        state.state = .playing
        sampledAt = Date()
        previousAcceptedState = state
        issue = nil
    }

    private func performSeekWithoutStartingPlayback(to seconds: Double) async {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let result = await controller.seek(to: position)
        lastActionFailed = !result.succeeded
        if result.permissionDenied {
            state.permissionDenied = true
            return
        }
        guard result.succeeded else { return }
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
            sessionPersistentID = ""
            sessionEstablished = false
            previousAcceptedState = MusicState()
            issue = nil
        }
        target = nextTarget
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
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
