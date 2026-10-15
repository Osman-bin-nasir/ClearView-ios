import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// The app's ONE background audio player.
///
/// The iOS counterpart of Android's `AudioPlaybackService` + `AudioPlayback`
/// facade, collapsed into one object because iOS has no equivalent of a
/// foreground service: an app with the `audio` background mode and an active
/// `.playback` audio session simply keeps playing when it leaves the foreground,
/// and the system draws its own lock-screen controls from whatever this object
/// publishes to `MPNowPlayingInfoCenter`.
///
/// ## Two sources, one engine
///
/// It plays a **downloaded file** and the **audio-only stream** of a video that
/// was never downloaded — the same player, the same lock-screen card and the
/// same sleep timer. That is the point: a reader who is listening does not care
/// whether the bytes came off the disk or off the network, and two engines would
/// mean two ways to stop.
@MainActor
@Observable
final class AudioPlaybackController {

    static let shared = AudioPlaybackController()

    /// What is loaded, so a screen can render "now playing" without the file.
    struct Track: Equatable {
        let videoId: String
        let title: String
        let channel: String
        let artworkURL: String?
        /// True for an audio-only stream rather than a saved file. A stream can
        /// outlive its signature and be re-resolved; a file cannot.
        let isStream: Bool
        let localFileURL: URL?
        let streamURL: URL?
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    /// True while waiting for bytes over a network stream. Only ever set for a
    /// stream — a local file is ready the moment it is asked for.
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Playback speed, 1.0 = normal. Persisted across sessions like Android's.
    private(set) var speed: Double = 1
    private(set) var error: String?

    /// Seconds left on the sleep timer, or 0 when no timer is set.
    private(set) var sleepRemaining: Double = 0
    /// True when the timer is set to stop at the end of what is playing.
    private(set) var sleepEndOfTrack = false
    /// The countdown the reader CHOSE, in minutes, or nil for no countdown.
    ///
    /// Held next to the deadline rather than re-derived from it, so a dialog's
    /// check mark stays on the row that was picked instead of drifting off it as
    /// the remaining time rounds down.
    private(set) var sleepChoiceMinutes: Int?

    /// Where a completed or paused stream session files its watch progress.
    ///
    /// A closure rather than a store because the library that owns watch
    /// progress is created per view in this app, and a background session runs
    /// with no view alive to ask. The Media tab installs this while it is on
    /// screen; without it a background listen simply is not recorded, which is
    /// the honest outcome rather than a crash.
    var progressSink: ((_ videoId: String, _ position: Double, _ duration: Double) -> Void)?

    /// Android's `MIN_SPEED` / `MAX_SPEED`. AVPlayer accepts a wider range, but
    /// matching Android keeps the two apps' controls identical.
    static let minSpeed: Double = 0.5
    static let maxSpeed: Double = 2

    /// Playback speed is remembered across launches, as it is on Android.
    private static let speedDefaultsKey = "media.audio.speed"

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var ticker: Timer?

    /// When the sleep timer fires (an absolute instant), or nil.
    ///
    /// An absolute deadline, not a total of playing time: the question the timer
    /// answers is "stop by the time I fall asleep", so pausing must not quietly
    /// buy the audio more minutes.
    private var sleepDeadline: Date?
    /// The last position reported, used to resume after a stream retry.
    private var lastPosition: Double = 0
    @ObservationIgnored private var streamResolver: (() async throws -> URL)?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    private(set) var isResolving = false

    private init() {
        speed = UserDefaults.standard.object(forKey: Self.speedDefaultsKey) as? Double ?? 1
        configureSession()
        configureRemoteCommands()
        observeInterruptions()
    }

    // MARK: - Loading and transport

    /// Plays a downloaded file.
    func playLocal(videoId: String, title: String, channel: String, artworkURL: String?, fileURL: URL, startAt: Double = 0) {
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        streamResolver = nil
        load(Track(videoId: videoId, title: title, channel: channel, artworkURL: artworkURL,
                   isStream: false, localFileURL: fileURL, streamURL: nil), startAt: startAt)
    }

    /// Plays the audio-only stream of a video that was not downloaded.
    func playStream(videoId: String, title: String, channel: String, artworkURL: String?, streamURL: URL, startAt: Double = 0,
                    resolver: (() async throws -> URL)? = nil) {
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        streamResolver = resolver
        load(Track(videoId: videoId, title: title, channel: channel, artworkURL: artworkURL,
                   isStream: true, localFileURL: nil, streamURL: streamURL), startAt: startAt)
    }

    private func load(_ newTrack: Track, startAt: Double, resetSleepTimer: Bool = true) {
        let safeStart = startAt.isFinite ? max(0, startAt) : 0
        teardownPlayer()
        track = newTrack
        error = nil
        position = safeStart
        duration = 0
        lastPosition = safeStart
        // A new source starts a new session: the previous track's sleep timer
        // does not belong to this one.
        if resetSleepTimer { clearSleepTimer() }
        activateSession()

        guard let url = newTrack.localFileURL ?? newTrack.streamURL else {
            MediaLog.audio.error("load \(newTrack.videoId, privacy: .public): no playable source")
            error = "There is nothing to play for this item."
            return
        }
        MediaLog.audio.info("load \(newTrack.videoId, privacy: .public): \(newTrack.isStream ? "stream" : "file", privacy: .public) startAt=\(startAt, privacy: .public)s host=\(url.host() ?? "-", privacy: .public)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = Float(speed)
        self.item = item
        self.player = player
        isBuffering = newTrack.isStream

        var didPrepare = false
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.item === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard !didPrepare else { return }
                    didPrepare = true
                    self.duration = item.duration.seconds.isFinite ? max(0, item.duration.seconds) : 0
                    self.isBuffering = false
                    MediaLog.audio.info("load \(newTrack.videoId, privacy: .public): readyToPlay duration=\(self.duration, privacy: .public)s")
                    if safeStart > 0 {
                        self.player?.seek(to: CMTime(seconds: safeStart, preferredTimescale: 600))
                    }
                    self.start()
                case .failed:
                    MediaLog.audio.error("load \(newTrack.videoId, privacy: .public): AVPlayerItem FAILED — \(String(describing: item.error), privacy: .public)")
                    self.error = self.readableError(item.error, isStream: newTrack.isStream)
                    self.isBuffering = false
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        // Playing → ended. A stream that ran to the end was genuinely listened
        // to, so it is recorded as watched — Android's `persistStreamProgress`.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.item === item else { return }
                self.finishPlayback()
            }
        }

        start()
    }

    /// Refresh an expired stream, retaining the listening position and timer.
    func retry() {
        guard let track, !isResolving else { return }
        guard track.isStream, let resolver = streamResolver else {
            load(track, startAt: position, resetSleepTimer: false)
            return
        }
        let resumeAt = position
        isResolving = true
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await resolver()
                try Task.checkCancellation()
                guard self.track?.videoId == track.videoId else { return }
                self.load(Track(videoId: track.videoId, title: track.title, channel: track.channel,
                                artworkURL: track.artworkURL, isStream: true, localFileURL: nil, streamURL: url),
                          startAt: resumeAt, resetSleepTimer: false)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self.isResolving = false
            self.resolveTask = nil
        }
    }

    /// Resume (or begin) playback of the loaded track.
    func start() {
        guard let player, track != nil else { return }
        activateSession()
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func pause() {
        guard track != nil else { return }
        player?.pause()
        isPlaying = false
        isBuffering = false
        persistProgress(completed: false)
        updateTickerLifecycle()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : start()
    }

    /// Stops and unloads; nothing is left to resume.
    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        streamResolver = nil
        persistProgress(completed: false)
        teardownPlayer()
        track = nil
        isPlaying = false
        isBuffering = false
        position = 0
        duration = 0
        error = nil
        clearSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
    }

    func seek(to seconds: Double) {
        guard let player, track != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        lastPosition = target
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Applies a playback speed and remembers it.
    func setSpeed(_ value: Double) {
        speed = min(Self.maxSpeed, max(Self.minSpeed, value))
        UserDefaults.standard.set(speed, forKey: Self.speedDefaultsKey)
        player?.defaultRate = Float(speed)
        // `rate` only takes effect while playing; a paused player picks the new
        // speed up on the next `start()`.
        if isPlaying { player?.rate = Float(speed) }
        updateNowPlaying()
    }

    // MARK: - Sleep timer

    func setSleep(countdownMinutes minutes: Int?) {
        if let minutes {
            let deadline = Date().addingTimeInterval(Double(minutes) * 60)
            sleepDeadline = deadline
            sleepEndOfTrack = false
            sleepRemaining = deadline.timeIntervalSinceNow
            sleepChoiceMinutes = minutes
            player?.volume = 1
            // Count down even from a paused player: the deadline is an instant,
            // not a total of listening, so it has to be able to end a session
            // nobody is currently hearing.
            startTicker()
        } else {
            clearSleepTimer()
        }
        updateNowPlaying()
    }

    func setSleepEndOfTrack() {
        sleepDeadline = nil
        sleepEndOfTrack = true
        sleepRemaining = 0
        sleepChoiceMinutes = nil
        player?.volume = 1
        updateNowPlaying()
    }

    func clearSleepTimer() {
        sleepDeadline = nil
        sleepEndOfTrack = false
        sleepRemaining = 0
        sleepChoiceMinutes = nil
        player?.volume = 1
    }

    /// True when any kind of timer is armed.
    var isSleepTimerArmed: Bool { sleepEndOfTrack || sleepRemaining > 0 }

    // MARK: - Session and remote controls

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        } catch {
            // Not fatal: playback still works, it just may be silenced by the
            // ringer switch.
            MediaLog.audio.error("audio session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Best effort — see configureSession. Logged because a session that
            // never activates is the classic cause of "the playhead moves but
            // nothing is audible".
            MediaLog.audio.error("audio session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Lock-screen / Control Center / headphone-button controls.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.start() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Pauses politely when something else takes the audio, and when the
    /// headphones are pulled out — Android's `AUDIOFOCUS_LOSS` handling.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    self?.pause()
                case .ended:
                    // Only auto-resume when the system says it is appropriate;
                    // resuming after a phone call is helpful, resuming after the
                    // reader pressed another app's play button is not.
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if options.contains(.shouldResume) { self?.start() }
                @unknown default:
                    break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        }
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - The playhead

    /// How often the playhead is sampled. One second, matching Android's ticker:
    /// currentTime is cheap but the sleep countdown and the lock-screen card only
    /// need to move a second at a time.
    private static let tickInterval: TimeInterval = 1

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Keeps the ticker alive only while it has something to do: a paused player
    /// with no timer would otherwise wake once a second forever.
    private func updateTickerLifecycle() {
        if isPlaying || sleepDeadline != nil {
            startTicker()
        } else {
            stopTicker()
        }
    }

    private func tick() {
        if let player {
            let seconds = player.currentTime().seconds
            if seconds.isFinite {
                position = max(0, seconds)
                lastPosition = position
            }
        }
        tickSleepTimer()
        if position > 0 { updateNowPlaying() }
        updateTickerLifecycle()
    }

    private func tickSleepTimer() {
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            // Out of time. The fade has already brought the volume down over the
            // last few seconds; this is silence and then a clean teardown,
            // leaving nothing that could resume when the phone is picked up.
            stop()
            return
        }
        sleepRemaining = remaining
        if isPlaying {
            player?.volume = SleepTimer.fadeVolume(remaining: remaining)
        }
    }

    private func finishPlayback() {
        let videoId = track?.videoId
        persistProgress(completed: true)
        if sleepEndOfTrack {
            stop()
            if let videoId { AudioDownloads.shared.markPlayed(videoId) }
            return
        }
        // Otherwise keep the track loaded, paused at 0, so the Play button
        // replays it — a dead end-of-track button is worse than a loaded track.
        player?.seek(to: .zero)
        isPlaying = false
        isBuffering = false
        position = 0
        clearSleepTimer()
        updateTickerLifecycle()
        updateNowPlaying()
        if let videoId, track?.isStream == false { AudioDownloads.shared.markPlayed(videoId) }
    }

    /// Files a stream's position as watch progress.
    ///
    /// Only for streams: a download's progress belongs to its own player screen,
    /// and filing it under the video's id from here would fight that screen's
    /// writes. Written at the three moments the position stops moving — paused,
    /// stopped, finished — never per tick.
    private func persistProgress(completed: Bool) {
        guard let track, track.isStream else { return }
        let total = completed ? duration : position
        guard duration > 0, total > 0 else { return }
        progressSink?(track.videoId, total, duration)
    }

    private func readableError(_ error: Error?, isStream: Bool) -> String {
        guard let error else {
            return isStream
                ? "This audio stream could not be played. It may have expired — try again."
                : "This downloaded file could not be played."
        }
        return "Playback failed. (\(error.localizedDescription))"
    }

    private func teardownPlayer() {
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
    }
}
