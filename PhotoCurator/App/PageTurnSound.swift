import AVFoundation

/// Plays the page-turn sound for the trip book's page navigation. A
/// synthesized paper-rustle sample (`PageTurn.wav` — procedurally
/// generated, not a recorded sound; swap the asset directly if a real
/// recording is preferred later).
///
/// A small round-robin pool of players, not one shared player: a single
/// `AVAudioPlayer.play()` call restarts from the beginning if called again
/// before the clip finishes, which audibly truncates the sound on a fast
/// double-flip (arrow-key repeat, rapid clicking). Three players is enough
/// headroom for that without the complexity of a full mixer.
@MainActor
enum PageTurnSound {
    private static let players: [AVAudioPlayer] = {
        guard let url = Bundle.main.url(forResource: "PageTurn", withExtension: "wav") else { return [] }
        return (0..<3).compactMap { _ in try? AVAudioPlayer(contentsOf: url) }
    }()
    private static var nextIndex = 0

    static func play() {
        guard !players.isEmpty else { return }
        let player = players[nextIndex]
        nextIndex = (nextIndex + 1) % players.count
        player.currentTime = 0
        player.play()
    }
}
