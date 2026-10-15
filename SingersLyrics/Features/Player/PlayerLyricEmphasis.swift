/// Share one readable dimmed state across platforms, including untimed lyrics
/// and the intro before the first cue.
enum PlayerLyricEmphasis {
    static func opacity(isActive: Bool) -> Double {
        isActive ? 1 : 0.42
    }
}
