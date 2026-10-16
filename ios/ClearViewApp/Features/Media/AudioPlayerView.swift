import SwiftUI

/// The background audio player screen — the counterpart of Android's
/// `AudioPlayerScreen`.
///
/// Deliberately reachable from anywhere audio is playing rather than only from
/// the screen that started it: the whole point of background playback is that
/// the reader has left that screen.
struct AudioPlayerView: View {
    @State private var controller = AudioPlaybackController.shared
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var showSleepTimer = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                artwork
                VStack(spacing: 6) {
                    Text(controller.track?.title ?? "Nothing playing")
                        .font(.title3.bold()).multilineTextAlignment(.center).lineLimit(3)
                    Text(controller.track?.channel ?? "")
                        .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    if controller.isBuffering {
                        Text("Buffering…").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                            .accessibilityIdentifier("audio.status")
                    }
                }
                if let error = controller.error {
                    Text(error).font(.footnote).foregroundStyle(Color.cvError).multilineTextAlignment(.center)
                    Button(controller.isResolving ? "Preparing audio…" : "Retry audio") { controller.retry() }
                        .disabled(controller.isResolving)
                        .accessibilityIdentifier("audio.retry")
                }
                timeline
                transport
                controls
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)
            .navigationTitle("Now playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheet(
                    chosenMinutes: controller.sleepChoiceMinutes,
                    endOfTrack: controller.sleepEndOfTrack,
                    onCountdown: { controller.setSleep(countdownMinutes: $0) },
                    onEndOfTrack: { controller.setSleepEndOfTrack() }
                )
            }
        }.tint(.cvPrimary).accessibilityIdentifier("audio.player")
    }

    private var artwork: some View {
        RemoteImage(url: controller.track?.artworkURL, maxPixelSize: 900, placeholder: AnyView(
            ZStack {
                Color.cvPrimaryContainer
                Image(systemName: "headphones").font(.system(size: 46)).foregroundStyle(Color.cvPrimary)
            }
        ))
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(Self.time(scrubbing ? scrubPosition : controller.position)).monospacedDigit()
            Slider(
                value: Binding(
                    get: { min(max(0, scrubbing ? scrubPosition : controller.position), max(1, controller.duration)) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(1, controller.duration),
                onEditingChanged: { editing in
                    if editing { scrubPosition = controller.position; scrubbing = true }
                    else { controller.seek(to: scrubPosition); scrubbing = false }
                }
            )
            .disabled(controller.duration <= 0)
            .accessibilityLabel("Playback timeline")
            .accessibilityIdentifier("audio.timeline")
            Text(controller.duration > 0 ? Self.time(controller.duration) : "--:--").monospacedDigit()
        }.font(.caption.bold()).foregroundStyle(Color.cvOnSurfaceVariant)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("Back 10 seconds", symbol: "gobackward.10") { controller.skip(by: -10) }
            transportButton(controller.isPlaying ? "Pause" : "Play",
                            symbol: controller.isPlaying ? "pause.fill" : "play.fill") { controller.togglePlayPause() }
                .accessibilityIdentifier("audio.playPause")
            transportButton("Forward 10 seconds", symbol: "goforward.10") { controller.skip(by: 10) }
        }.padding(.vertical, 4)
    }

    private func transportButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 34))
                .foregroundStyle(Color.cvPrimary).frame(maxWidth: .infinity).frame(height: 56)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    /// The bottom row: playback speed and the sleep timer — the two controls
    /// whose whole job is to act later, while nobody is looking.
    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        controller.setSpeed(rate)
                    } label: {
                        if abs(controller.speed - rate) < 0.001 { Label("\(rate.formatted())×", systemImage: "checkmark") }
                        else { Text("\(rate.formatted())×") }
                    }
                }
            } label: {
                pill(title: "\(controller.speed.formatted())×", symbol: "speedometer", armed: controller.speed != 1)
            }.accessibilityIdentifier("audio.speed")

            Button { showSleepTimer = true } label: {
                pill(
                    title: SleepTimer.label(forRemaining: controller.sleepRemaining),
                    symbol: "moon.zzz",
                    armed: controller.isSleepTimerArmed
                )
            }.accessibilityIdentifier("audio.sleepTimer")

            Spacer(minLength: 0)

            Button { controller.stop(); dismiss() } label: {
                Image(systemName: "stop.fill").font(.system(size: 16)).frame(width: 44, height: 38)
            }.accessibilityLabel("Stop")
        }
    }

    private func pill(title: String, symbol: String, armed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(armed ? Color.cvPrimary : Color.cvOnSurfaceVariant)
        .background(armed ? Color.cvPrimary.opacity(0.16) : Color.cvSurfaceContainer, in: Capsule())
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The sleep timer picker.
///
/// A list rather than a slider or a number field: this is set in the dark, on
/// the way to sleep, and choosing one of six rows with a thumb is a different
/// thing from aiming a thumb at a specific pixel.
///
/// Both kinds of timer live in one list on purpose — "Off", the countdowns and
/// "End of this track" are all answers to the same question, and exactly one
/// check mark shows which answer is in force.
struct SleepTimerSheet: View {
    let chosenMinutes: Int?
    let endOfTrack: Bool
    let onCountdown: (Int?) -> Void
    let onEndOfTrack: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(label: "Off", selected: !endOfTrack && chosenMinutes == nil) { onCountdown(nil) }
                ForEach(SleepTimer.minutes, id: \.self) { minutes in
                    row(label: Self.minutesLabel(minutes), selected: !endOfTrack && chosenMinutes == minutes) {
                        onCountdown(minutes)
                    }
                }
                row(label: "End of this track", selected: endOfTrack) { onEndOfTrack() }
            }
            .navigationTitle("Sleep timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(.cvPrimary)
    }

    private func row(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.cvPrimary : Color.cvOnSurface)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.cvPrimary) }
            }
        }.buttonStyle(.plain)
    }

    private static func minutesLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")" : "\(minutes) minutes"
    }
}
