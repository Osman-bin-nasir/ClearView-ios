import AVFoundation
import Observation

/// Where a single verse's recitation is in its lifecycle.
///
/// The iOS counterpart of `VerseAudioStatus` in
/// `quran/ui/VerseAudioPlayer.kt` — the same six states, in the same order, with
/// the same meaning. There is no DOWNLOADING state and no transfer progress
/// because the file is streamed: "loading" is the gap between the tap and the
/// first sound, not a transfer anyone would watch.
enum VerseAudioStatus {
    case idle
    case loading
    case playing
    case paused
    case ended
    case failed
}

/// The reciter whose per-ayah files the Listen control streams.
///
/// everyayah.com publishes one MP3 per ayah, named `<surah><ayah>` with each
/// number zero-padded to three digits (`001001.mp3` = Al-Faatiha, ayah 1), which
/// is exactly the granularity Listen needs: one verse, one file, nothing kept on
/// the device. Byte-for-byte the same base URL as the Android player's
/// `RECITER_BASE`, so both platforms play the same recitation.
enum VerseAudio {
    static let reciterBase = "https://everyayah.com/data/Alafasy_128kbps"

    /// The per-ayah MP3 URL for one verse — Android's `verseAudioUrl`.
    static func url(surahNumber: Int32, ayahNumber: Int32) -> URL? {
        URL(string: String(format: "%@/%03d%03d.mp3", reciterBase, surahNumber, ayahNumber))
    }

    /// `m:ss` for a millisecond position, as an audio player shows it.
    static func time(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Streams ONE verse's recitation.
///
/// Deliberately not the app's background audio system (which exists for
/// downloaded media with lock-screen controls): listening to a verse is a few
/// seconds long, started from a screen the reader is looking at, and should end
/// when they leave it. Nothing is written to disk, so the feature costs no
/// storage — which is the whole reason it streams instead of downloading.
///
/// `@Observable` so the controls follow it, and an explicit `release()` rather
/// than a deinit, exactly as the Android player makes its `MediaPlayer` lifetime
/// explicit: the recitation must stop the moment the verse changes, not whenever
/// the object happens to be collected.
@MainActor
@Observable
final class VerseAudioPlayer {

    private(set) var status: VerseAudioStatus = .idle

    /// How far into the loaded recitation playback is, in milliseconds.
    private(set) var positionMs = 0

    /// The loaded recitation's full length in milliseconds, or 0 until known.
    private(set) var durationMs = 0

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// True once the file is prepared — the point at which a seek bar has
    /// something meaningful to drag. Android draws its bar on the same condition.
    var isLoaded: Bool {
        durationMs > 0 && (status == .playing || status == .paused || status == .ended)
    }

    /// Begin (or retry) playback of `url` from the start.
    func start(_ url: URL) {
        release()
        status = .loading

        do {
            // `.playback`/`.spokenAudio` so the recitation is audible with the
            // ringer switch off, which is what a reader expects of scripture —
            // and the same intent as Android's USAGE_MEDIA/MUSIC attributes.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            release()
            status = .failed
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.item = item
        self.player = player

        // Prepared → playing. AVPlayer has no "prepared" callback of its own, so
        // the item's status is observed; that is also where a stream that will
        // never load reports itself, which is the Android player's onError path.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.durationMs = max(0, Int((item.duration.seconds.isFinite ? item.duration.seconds : 0) * 1000))
                    if self.status == .loading {
                        player.play()
                        self.status = .playing
                        self.startTicker()
                    }
                case .failed:
                    self.release()
                    self.status = .failed
                default:
                    break
                }
            }
        }

        // Playing → ended, with the playhead landed on the end so a finished
        // recitation reads full rather than wherever the last tick happened to
        // be. Android's onCompletion does the same.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncProgress()
                self.positionMs = self.durationMs
                self.status = .ended
                self.stopTicker()
            }
        }

        player.play()
    }

    /// Pause the loaded recitation; a no-op unless it is actually playing.
    func pause() {
        guard status == .playing else { return }
        player?.pause()
        syncProgress()
        status = .paused
        stopTicker()
    }

    /// Resume a paused recitation; a no-op unless it is actually paused.
    func resume() {
        guard status == .paused else { return }
        player?.play()
        status = .playing
        startTicker()
    }

    /// Replay the loaded verse from its first second.
    func restart() {
        guard let player, status != .idle, status != .loading else { return }
        player.seek(to: .zero)
        player.play()
        positionMs = 0
        status = .playing
        startTicker()
    }

    /// Move the playhead to `ms`.
    ///
    /// A no-op until the file is prepared, because there is nothing to seek in
    /// yet. Seeking inside a FINISHED recitation leaves it paused at the new spot
    /// rather than ended, so the Listen button reads "Resume" and the reader can
    /// pick the ayah up from where they dragged to.
    func seek(toMilliseconds ms: Int) {
        guard let player, status != .idle, status != .loading else { return }
        let upper = durationMs > 0 ? durationMs : ms
        let target = min(max(0, ms), upper)
        player.seek(to: CMTime(value: CMTimeValue(target), timescale: 1000))
        positionMs = target
        if status == .ended {
            status = .paused
            stopTicker()
        }
    }

    /// Stop and free everything; the next play re-fetches from the start.
    func release() {
        stopTicker()
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        item = nil
        status = .idle
        positionMs = 0
        durationMs = 0
    }

    // MARK: - The playhead

    /// How often the playhead is sampled while a recitation is playing. Android's
    /// `PROGRESS_TICK_MS`: `currentTime` is a cheap read on iOS but the reason is
    /// the same — a number only the bar needs should not be read every frame.
    private static let tickIntervalMs = 250

    private func startTicker() {
        stopTicker()
        let interval = CMTime(value: CMTimeValue(Self.tickIntervalMs), timescale: 1000)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .playing else { return }
                self.syncProgress()
            }
        }
    }

    private func stopTicker() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func syncProgress() {
        guard let player else { return }
        positionMs = max(0, Int(player.currentTime().seconds * 1000))
        if let item, item.duration.seconds.isFinite, item.duration.seconds > 0 {
            durationMs = Int(item.duration.seconds * 1000)
        }
    }
}
