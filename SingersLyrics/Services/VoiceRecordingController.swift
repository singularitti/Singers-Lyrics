import Foundation
import Observation
@preconcurrency import AVFoundation

/// Owns the one microphone capture or recorded-take playback used by the app.
@MainActor
@Observable
final class VoiceRecordingController: NSObject {
    var prepareForAudio: (@MainActor () async -> Bool)?
    var onRecordingFinished: (@MainActor (UUID, UUID, VoiceRecording) -> Void)?

    var errorMessage: String?
    /// Lets the error presentation offer the system privacy settings.
    private(set) var microphoneAccessDenied = false
    private(set) var recordingSongID: UUID?
    private(set) var recordingLineID: UUID?
    private(set) var playingSongID: UUID?
    private(set) var playingLineID: UUID?
    private(set) var playingRecordingID: UUID?
    private(set) var isPreparing = false
    private(set) var elapsed: Double = 0

    private struct Capture {
        var songID: UUID
        var lineID: UUID
        var name: String
        var createdAt: Date
        var url: URL
        var duration: Double = 0
    }

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    #if os(iOS)
    private struct AudioSessionConfiguration {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode
        var options: AVAudioSession.CategoryOptions
    }

    /// The app's configuration before the first take used the shared session.
    @ObservationIgnored private var restoredAudioSession: AudioSessionConfiguration?
    @ObservationIgnored private var keepsAudioSession = false
    #endif

    var hasUncommittedRecording: Bool { capture != nil }

    func record(songID: UUID, lineID: UUID, name: String) async {
        stopBeforeNextAction()
        // Preserve a completed file if an earlier read or delivery failed.
        guard capture == nil else {
            releaseAudioSessionIfIdle()
            errorMessage = "Your previous recording could not be saved. Try stopping again before recording another take."
            return
        }
        errorMessage = nil
        microphoneAccessDenied = false
        operationGeneration &+= 1
        let generation = operationGeneration
        recordingSongID = songID
        recordingLineID = lineID
        isPreparing = true
        elapsed = 0

        let permission = await microphonePermission()
        guard isCurrent(generation) else { return }
        guard permission else {
            clearRecordingState()
            microphoneAccessDenied = true
            errorMessage = VoiceRecordingMessage.microphoneAccessDenied
            return
        }
        let ready = await prepareForAudio?() ?? true
        guard isCurrent(generation) else { return }
        guard ready else {
            clearRecordingState()
            errorMessage = VoiceRecordingMessage.songNotPausedForRecording
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingersLyrics-Voice-\(UUID().uuidString).m4a")
        do {
            #if os(iOS)
            try activateAudioSession(forRecording: true)
            #endif
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            newRecorder.delegate = self
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                newRecorder.delegate = nil
                newRecorder.stop()
                try? FileManager.default.removeItem(at: url)
                clearRecordingState()
                errorMessage = VoiceRecordingMessage.microphoneUnavailable
                return
            }
            capture = Capture(
                songID: songID,
                lineID: lineID,
                name: name,
                createdAt: Date(),
                url: url
            )
            recorder = newRecorder
            isPreparing = false
            startClock()
        } catch {
            try? FileManager.default.removeItem(at: url)
            clearRecordingState()
            errorMessage = VoiceRecordingMessage.microphoneUnavailable
        }
    }

    func play(_ recording: VoiceRecording, songID: UUID, lineID: UUID) async {
        stopBeforeNextAction()
        guard capture == nil else {
            releaseAudioSessionIfIdle()
            errorMessage = "Your previous recording could not be saved. Try stopping again before playing a take."
            return
        }
        errorMessage = nil
        microphoneAccessDenied = false
        operationGeneration &+= 1
        let generation = operationGeneration
        playingSongID = songID
        playingLineID = lineID
        playingRecordingID = recording.id
        isPreparing = true
        elapsed = 0
        let ready = await prepareForAudio?() ?? true
        guard isCurrent(generation) else { return }
        guard ready else {
            stopPlayback()
            errorMessage = VoiceRecordingMessage.songNotPausedForPlayback
            return
        }
        do {
            guard !recording.audioData.isEmpty else {
                stopPlayback()
                errorMessage = "This recording's audio is missing. Restore its audio file or record another take."
                return
            }
            #if os(iOS)
            try activateAudioSession(forRecording: false)
            #endif
            let newPlayer = try AVAudioPlayer(data: recording.audioData)
            newPlayer.delegate = self
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                newPlayer.delegate = nil
                newPlayer.stop()
                stopPlayback()
                errorMessage = "The recording could not play. Check your audio output and try again."
                return
            }
            player = newPlayer
            isPreparing = false
            startClock()
        } catch {
            stopPlayback()
            errorMessage = "The recording could not play. Its audio may be damaged or unavailable."
        }
    }

    /// Stop and deliver synchronously so navigation and termination retain audio.
    func finishRecording() {
        let retryingCompletedCapture = recorder == nil && capture != nil
        if recordingSongID != nil || recorder != nil {
            operationGeneration &+= 1
            clockTask?.cancel()
            clockTask = nil
        }
        if let recorder {
            let previousDuration = capture?.duration ?? 0
            capture?.duration = max(previousDuration, max(recorder.currentTime, elapsed))
            recorder.delegate = nil
            recorder.stop()
            self.recorder = nil
        }
        clearRecordingState()
        guard let completed = capture else { return }
        do {
            let audioData = try Data(contentsOf: completed.url)
            let decoded = try AVAudioPlayer(data: audioData)
            let duration = max(completed.duration, decoded.duration)
            guard !audioData.isEmpty, decoded.duration > 0, duration.isFinite else {
                errorMessage = "The microphone did not capture usable audio. Try recording again."
                capture = nil
                try? FileManager.default.removeItem(at: completed.url)
                return
            }
            guard let onRecordingFinished else {
                showPendingCapture(completed)
                errorMessage = "Your recording is waiting to be saved. Try stopping again."
                return
            }
            let take = VoiceRecording(
                name: completed.name,
                createdAt: completed.createdAt,
                duration: duration,
                audioData: audioData
            )
            // Clear ownership before the callback, which may update the library.
            capture = nil
            if retryingCompletedCapture { errorMessage = nil }
            onRecordingFinished(completed.songID, completed.lineID, take)
            try? FileManager.default.removeItem(at: completed.url)
        } catch {
            // Keep the closed source file available for a later finish retry.
            showPendingCapture(completed)
            errorMessage = "Your recording could not be read and has been kept temporarily. Try stopping again to save it."
        }
    }

    func cancelRecording() {
        operationGeneration &+= 1
        if recordingSongID != nil || recorder != nil {
            clockTask?.cancel()
            clockTask = nil
        }
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let capture { try? FileManager.default.removeItem(at: capture.url) }
        capture = nil
        clearRecordingState()
    }

    func stopPlayback() {
        if playingSongID != nil || player != nil {
            operationGeneration &+= 1
            clockTask?.cancel()
            clockTask = nil
            isPreparing = false
            elapsed = 0
        }
        player?.delegate = nil
        player?.stop()
        player = nil
        playingSongID = nil
        playingLineID = nil
        playingRecordingID = nil
        releaseAudioSessionIfIdle()
    }

    func stop() {
        operationGeneration &+= 1
        finishRecording()
        stopPlayback()
    }

    /// Switching directly between takes keeps the iOS audio session active, so
    /// other apps are not told to resume between the two actions.
    private func stopBeforeNextAction() {
        #if os(iOS)
        keepsAudioSession = true
        defer { keepsAudioSession = false }
        #endif
        stop()
    }

    func reconcile(with songs: [Song]) {
        if let songID = recordingSongID, let lineID = recordingLineID,
           songs.first(where: { $0.id == songID })?.lines.contains(where: { $0.id == lineID }) != true {
            cancelRecording()
        }
        if let capture,
           songs.first(where: { $0.id == capture.songID })?.lines.contains(where: { $0.id == capture.lineID }) != true {
            cancelRecording()
        }
        if let songID = playingSongID, let lineID = playingLineID, let recordingID = playingRecordingID,
           songs.first(where: { $0.id == songID })?.lines.first(where: { $0.id == lineID })?.recordings.contains(where: { $0.id == recordingID }) != true {
            stopPlayback()
        }
    }

    private func microphonePermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    #if os(iOS)
    private func activateAudioSession(forRecording recording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if restoredAudioSession == nil {
            restoredAudioSession = AudioSessionConfiguration(
                category: session.category,
                mode: session.mode,
                options: session.categoryOptions
            )
        }
        if recording {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }
    #endif

    /// Returns the shared iOS session once no capture or take playback remains.
    private func releaseAudioSessionIfIdle() {
        #if os(iOS)
        guard !keepsAudioSession, recorder == nil, player == nil,
              let configuration = restoredAudioSession else { return }
        restoredAudioSession = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
        #endif
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        guard operationGeneration == generation else { return false }
        if Task.isCancelled {
            if recordingSongID != nil { cancelRecording() }
            if playingSongID != nil { stopPlayback() }
            return false
        }
        return true
    }

    private func clearRecordingState() {
        if recordingSongID != nil {
            isPreparing = false
            elapsed = 0
        }
        recordingSongID = nil
        recordingLineID = nil
        releaseAudioSessionIfIdle()
    }

    private func showPendingCapture(_ completed: Capture) {
        recordingSongID = completed.songID
        recordingLineID = completed.lineID
        elapsed = completed.duration
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self else { return }
                self.updateElapsed()
            }
        }
    }

    private func updateElapsed() {
        if let recorder {
            elapsed = max(elapsed, recorder.currentTime)
            if !recorder.isRecording {
                errorMessage = "Recording stopped because the audio input was interrupted. Any usable captured audio will be saved."
                finishRecording()
            }
        } else if let player {
            elapsed = player.currentTime
            if !player.isPlaying { stopPlayback() }
        }
    }

    private func recorderFinished(_ identifier: ObjectIdentifier, successfully: Bool) {
        guard let recorder, ObjectIdentifier(recorder) == identifier else { return }
        if !successfully {
            errorMessage = "Recording was interrupted. Any usable captured audio will be saved."
        }
        finishRecording()
    }

    private func recorderFailed(_ identifier: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == identifier else { return }
        errorMessage = "The audio input stopped working. Any usable captured audio will be saved."
        finishRecording()
    }

    private func playerFinished(_ identifier: ObjectIdentifier, successfully: Bool) {
        guard let player, ObjectIdentifier(player) == identifier else { return }
        stopPlayback()
        if !successfully { errorMessage = "Playback was interrupted. Try playing the recording again." }
    }
}

extension VoiceRecordingController: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.recorderFinished(identifier, successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let identifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.recorderFailed(identifier) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playerFinished(identifier, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playerFinished(identifier, successfully: false) }
    }
}

private enum VoiceRecordingMessage {
    #if os(iOS)
    static let microphoneAccessDenied = "Microphone access is required to record your voice. Allow it in Settings > Privacy & Security > Microphone."
    static let songNotPausedForRecording = "The song could not be paused. Pause it, then try recording again."
    static let songNotPausedForPlayback = "The song could not be paused. Pause it, then try playing your recording again."
    static let microphoneUnavailable = "The microphone could not start recording. End any call or other recording, then try again."
    #else
    static let microphoneAccessDenied = "Microphone access is required to record your voice. Allow it in System Settings > Privacy & Security > Microphone."
    static let songNotPausedForRecording = "The song could not be paused. Pause it in Music, then try recording again."
    static let songNotPausedForPlayback = "The song could not be paused. Pause it in Music, then try playing your recording again."
    static let microphoneUnavailable = "The microphone could not start recording. Check your audio input in System Settings and try again."
    #endif
}
