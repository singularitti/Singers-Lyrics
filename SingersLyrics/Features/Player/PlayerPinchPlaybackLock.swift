import Observation

/// Consume lyric clicks from a pinch, including the final touch or mouse release.
@MainActor
@Observable
final class PlayerPinchPlaybackLock {
    private(set) var isLocked = false
    @ObservationIgnored private var isPinching = false
    @ObservationIgnored private var session: UInt = 0
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    func beginPinch() {
        guard !isPinching else { return }
        releaseTask?.cancel()
        releaseTask = nil
        session &+= 1
        isPinching = true
        isLocked = true
    }

    func endPinch() {
        guard isPinching else { return }
        isPinching = false
        let completedSession = session
        // A pinch can end before the button receives its final release event.
        // Keep that event from being interpreted as a fresh lyric activation.
        releaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.session == completedSession, !self.isPinching else { return }
            self.isLocked = false
            self.releaseTask = nil
        }
    }

    func reset() {
        releaseTask?.cancel()
        releaseTask = nil
        session &+= 1
        isPinching = false
        isLocked = false
    }
}
