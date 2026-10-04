#if os(iOS)
import Foundation
import MediaPlayer
import OSLog

/// Plays a single linked Apple Music store item in this app's private queue.
@MainActor
final class IOSMusicController: MusicControlling {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SingersLyrics",
        category: "MusicPlayback"
    )

    private let player = MPMusicPlayerController.applicationMusicPlayer
    private var openGeneration: UInt64 = 0

    func currentState() async -> MusicState {
        // Polling starts with the workspace. Wait for an explicit playback
        // action to request access before reading any media-library metadata.
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            return MusicState(permissionDenied: Self.isAuthorizationDenied)
        }
        let item = player.nowPlayingItem
        let storeID = item?.playbackStoreID ?? ""
        let persistentID = item?.persistentID ?? 0
        let identity: String
        if let catalogID = Self.validNonzeroNumericID(storeID) {
            identity = "catalog:\(catalogID)"
        } else if persistentID != 0 {
            identity = "library:\(persistentID)"
        } else {
            identity = ""
        }

        let playbackState: PlaybackState = switch player.playbackState {
        case .playing: .playing
        case .paused, .interrupted, .seekingBackward, .seekingForward: .paused
        case .stopped: .stopped
        @unknown default: .stopped
        }

        return MusicState(
            state: playbackState,
            position: Self.finiteNonnegative(player.currentPlaybackTime),
            duration: Self.finiteNonnegative(item?.playbackDuration ?? 0),
            trackName: item?.title ?? "",
            trackArtist: item?.artist ?? "",
            trackPersistentID: identity,
            permissionDenied: Self.isAuthorizationDenied
        )
    }

    func openTrack(_ url: URL, title _: String, artist _: String) async -> MusicActionResult {
        openGeneration &+= 1
        let generation = openGeneration
        guard let trackID = ITunesTrackMetadataService.trackID(from: url),
              let validID = Self.validNonzeroNumericID(trackID) else {
            return MusicActionResult(
                succeeded: false,
                permissionDenied: false,
                failure: MusicPlaybackFailure(reason: .invalidLink, stage: .catalog, code: "invalidSongLink")
            )
        }
        let authorization = await requestAuthorizationIfNeeded()
        guard generation == openGeneration, !Task.isCancelled else { return Self.failure() }
        guard authorization == .authorized else {
            return Self.failure(permissionDenied: authorization == .denied || authorization == .restricted)
        }

        let queue = MPMusicPlayerStoreQueueDescriptor(storeIDs: [validID])
        queue.startItemID = validID
        player.repeatMode = .none
        player.shuffleMode = .off
        player.setQueue(with: queue)

        do {
            try await prepareToPlay()
            guard generation == openGeneration, !Task.isCancelled else { return Self.failure() }
            player.play()
            return MusicActionResult(succeeded: true, permissionDenied: false)
        } catch {
            return Self.failure(error, stage: .playback)
        }
    }

    func playPause() async -> MusicState {
        openGeneration &+= 1
        let generation = openGeneration
        var actionFailed = false
        var failure: MusicPlaybackFailure?

        if player.playbackState == .playing {
            player.pause()
        } else {
            let authorization = await requestAuthorizationIfNeeded()
            guard generation == openGeneration, !Task.isCancelled else { return await currentState() }
            if authorization != .authorized {
                actionFailed = true
            } else {
                do {
                    if !player.isPreparedToPlay {
                        try await prepareToPlay()
                        guard generation == openGeneration, !Task.isCancelled else {
                            return await currentState()
                        }
                    }
                    player.play()
                } catch {
                    actionFailed = true
                    failure = Self.failure(error, stage: .resume).failure
                }
            }
        }

        var result = await currentState()
        result.actionFailed = actionFailed
        result.failure = failure
        return result
    }

    func seek(to seconds: Double) async -> MusicActionResult {
        openGeneration &+= 1
        let generation = openGeneration
        let authorization = await requestAuthorizationIfNeeded()
        guard generation == openGeneration, !Task.isCancelled else { return Self.failure() }
        guard authorization == .authorized else {
            return Self.failure(permissionDenied: authorization == .denied || authorization == .restricted)
        }
        player.currentPlaybackTime = Self.clampedPosition(seconds, duration: player.nowPlayingItem?.playbackDuration ?? 0)
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func seekAndPlay(to seconds: Double) async -> MusicActionResult {
        openGeneration &+= 1
        let generation = openGeneration
        let authorization = await requestAuthorizationIfNeeded()
        guard generation == openGeneration, !Task.isCancelled else { return Self.failure() }
        guard authorization == .authorized else {
            return Self.failure(permissionDenied: authorization == .denied || authorization == .restricted)
        }

        do {
            if !player.isPreparedToPlay {
                try await prepareToPlay()
                guard generation == openGeneration, !Task.isCancelled else { return Self.failure() }
            }
            player.currentPlaybackTime = Self.clampedPosition(
                seconds,
                duration: player.nowPlayingItem?.playbackDuration ?? 0
            )
            player.play()
            return MusicActionResult(succeeded: true, permissionDenied: false)
        } catch {
            return Self.failure(error, stage: .seek)
        }
    }

    func stop() async -> MusicActionResult {
        openGeneration &+= 1
        player.stop()
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    private func requestAuthorizationIfNeeded() async -> MPMediaLibraryAuthorizationStatus {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized, .denied, .restricted:
            MPMediaLibrary.authorizationStatus()
        case .notDetermined:
            await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        @unknown default:
            MPMediaLibrary.authorizationStatus()
        }
    }

    private func prepareToPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            player.prepareToPlay(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static var isAuthorizationDenied: Bool {
        let status = MPMediaLibrary.authorizationStatus()
        return status == .denied || status == .restricted
    }

    private static func failure(permissionDenied: Bool = false) -> MusicActionResult {
        MusicActionResult(succeeded: false, permissionDenied: permissionDenied)
    }

    private static func failure(_ error: any Error, stage: MusicPlaybackFailure.Stage) -> MusicActionResult {
        let failure = MusicPlaybackFailure.classify(error, stage: stage)
        logger.error("Apple Music request failed: \(failure.diagnostic, privacy: .public)")
        return MusicActionResult(
            succeeded: false,
            permissionDenied: isAuthorizationDenied,
            failure: failure
        )
    }

    private static func validNonzeroNumericID(_ value: String) -> String? {
        guard let numericID = UInt64(value), numericID != 0 else { return nil }
        return value
    }

    private static func clampedPosition(_ seconds: Double, duration: Double) -> Double {
        let position = seconds.isFinite ? max(0, seconds) : 0
        let finiteDuration = finiteNonnegative(duration)
        return finiteDuration > 0 ? min(position, finiteDuration) : position
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
#endif
