import SwiftUI
import SharedKotlin

/// The Quran tab — the app's home page.
///
/// A port of Android's `quran/ui/QuranTab.kt` plus the Quran branch of
/// `ui/ContentHub.kt`'s top bar, laid out in the same order with the same strings
/// (`quran_verse_header`, `quran_verse_previous`, `quran_ayah_reference_of`, …)
/// and the same measurements: 24-point page padding, a 24-point surah name, a
/// 132×3 progress bar, 30-point Arabic at the reader's scale, and a row of two
/// equal-width actions at the bottom.
///
/// The verse is the complete one — surah name and its meaning, the reference with
/// the reader's position inside the surah, the Arabic, Previous/Next, the English
/// translation, and then the controls. Below it, the Umm al-Qura date with the
/// small edit target that opens the ±1 day adjustment, exactly as Android draws
/// it.
///
/// Everything the reader can do is in the top bar, in Android's order: headphones
/// reveal the Listen control, the magnifier opens search/surah/bookmarks, the
/// bookmark icon saves the verse on screen, and the bell opens every notification
/// the app has.
struct QuranView: View {

    @State private var model = QuranModel()
    @State private var audio = VerseAudioPlayer()
    @State private var toast: String?
    @State private var showLibrary = false
    @State private var showNotifications = false
    @State private var showIslamicDateSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                page
            }
            .background(Color.cvBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLibrary) {
                QuranLibraryView()
            }
            .task { await model.load() }
            .onDisappear { audio.release() }
            .sheet(isPresented: $showNotifications) {
                NotificationsSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showIslamicDateSheet) {
                IslamicDateAdjustmentSheet(
                    adjustment: model.islamicDateAdjustment,
                    onSelect: { model.setIslamicDateAdjustment($0) }
                )
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.hidden)
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(CVFont.bodyMedium)
                        .foregroundStyle(Color.cvInverseOnSurface)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.cvInverseSurface, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Top bar (ContentHubTopBar's Quran branch)

    private var topBar: some View {
        CVTopBar(title: "Quran Reminder") {
            EmptyView()
        } trailing: {
            Group {
                // Listen: reveals (or hides) the verse page's audio control. In the
                // bar rather than on the page so the reading view is unchanged for
                // someone who never uses it. Accent-tinted while it is showing, so
                // the icon says which state a second tap will leave.
                CVIconButton(
                    systemName: "headphones",
                    label: "Listen",
                    tint: model.showVerseListen ? .cvPrimary : .cvOnSurfaceVariant,
                    enabled: model.currentVerse != nil && !isLoading,
                    identifier: "quran.listen.toggle"
                ) {
                    model.showVerseListen.toggle()
                    if !model.showVerseListen { audio.release() }
                }
                CVIconButton(
                    systemName: "magnifyingglass",
                    label: "Search Quran",
                    enabled: model.currentVerse != nil && !isLoading,
                    identifier: "quran.search"
                ) { showLibrary = true }
                // Filled and accent-tinted when bookmarked, outlined and muted
                // otherwise — the state change is unmistakable at a glance.
                CVIconButton(
                    systemName: model.isBookmarked ? "bookmark.fill" : "bookmark",
                    label: "Bookmark",
                    tint: model.isBookmarked ? .cvPrimary : .cvOnSurfaceVariant,
                    enabled: model.currentVerse != nil && !isLoading,
                    identifier: "quran.bookmark",
                    // The glyph is the only thing that changes, and a filled
                    // bookmark says nothing out loud — so the state is spoken.
                    value: model.isBookmarked ? "saved" : "not saved"
                ) {
                    let added = model.toggleBookmark()
                    say(added ? "Verse bookmarked" : "Bookmark removed")
                }
                CVBadgedIconButton(
                    systemName: unreadNotificationCount > 0 ? "bell.fill" : "bell",
                    label: "Notifications",
                    count: unreadNotificationCount,
                    tint: unreadNotificationCount > 0 ? .cvPrimary : .cvOnSurfaceVariant,
                    enabled: model.currentVerse != nil && !isLoading,
                    identifier: "quran.notifications"
                ) { showNotifications = true }
            }
        }
    }

    /// What the bell counts. Android's bell sums every leg — media updates, due
    /// To Do reminders and the Quran cadence — and the Quran leg never counts,
    /// because a cadence is a standing arrangement rather than something that
    /// happened. The media and To Do legs arrive with those tabs.
    private var unreadNotificationCount: Int { 0 }

    // MARK: - The page (QuranTab)

    private var isLoading: Bool {
        if case .loading = model.state { return true }
        return false
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading && model.currentVerse == nil {
                    Spacer().frame(height: 48)
                    ProgressView().tint(.cvPrimary)
                    Spacer().frame(height: 16)
                    Text("Loading verse…")
                        .font(CVFont.bodyMedium)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                } else if let verse = model.currentVerse {
                    VerseDisplay(
                        verse: verse,
                        model: model,
                        audio: audio,
                        onCopy: {
                            UIPasteboard.general.string = model.clipboardText(for: verse)
                            say("Verse copied to clipboard")
                        }
                    )
                } else {
                    Spacer().frame(height: 48)
                    Text("🕋").font(.system(size: 56))
                    Spacer().frame(height: 16)
                    // Shown only when the first-run download could not complete
                    // (e.g. offline), which is Android's wording for the same case.
                    Text("Quran verses are downloading.\nPlease close and reopen ClearView once the download is complete.")
                        .font(CVFont.bodyMedium)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                }

                // ── Islamic date (Umm al-Qura / Saudi Arabia) ──────────────
                Spacer().frame(height: 28)
                CVDivider()
                Spacer().frame(height: 16)
                IslamicDateRow(
                    adjustment: model.islamicDateAdjustment,
                    onEdit: { showIslamicDateSheet = true }
                )
                Spacer().frame(height: 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.cvBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func say(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

/// The full verse reading view — `VerseDisplay` in `QuranTab.kt`.
///
/// Every child is a plain element of the scrolling column: the note the Android
/// file carries says the Previous/Next row used to be an overlay and now sits in
/// the normal flow so it pushes the translation down rather than covering it. It
/// is in that order here too.
private struct VerseDisplay: View {

    let verse: QuranVerse
    let model: QuranModel
    let audio: VerseAudioPlayer
    let onCopy: () -> Void

    /// While the thumb is held, the dragged value is shown rather than the
    /// ticking playhead — otherwise every 250 ms tick would yank the thumb back
    /// under the finger. The player is only told to seek once the drag ends.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 8)

            // Surah name and its meaning.
            Text(verse.surahName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.cvOnSurface)
                .multilineTextAlignment(.center)
            if !verse.surahTranslation.isEmpty {
                Spacer().frame(height: 4)
                Text(verse.surahTranslation)
                    .font(CVFont.bodyMedium)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 8)

            // ONE reference line, with the reader's position inside the surah
            // folded into it — Android folded the separate "2 / 5 ayahs" line into
            // this one and drew the position as a bar instead.
            Text(reference)
                .font(CVFont.labelLarge)
                .foregroundStyle(Color.cvPrimary)
                .multilineTextAlignment(.center)
                // Android gives this line the spoken form "Ayah 3 of 7 in this
                // surah" while drawing "Surah 2 · Ayah 3 of 7" — the bar says the
                // position once, without the number read twice. Same here, and the
                // identifier is on it so a test can read the verse the page is
                // actually showing rather than guessing at it.
                .accessibilityLabel(
                    verse.totalAyahs > 0
                        ? "Ayah \(verse.ayahNumber) of \(verse.totalAyahs) in this surah"
                        : reference
                )
                .accessibilityIdentifier("quran.verse.position")

            if verse.totalAyahs > 0 {
                Spacer().frame(height: 9)
                ProgressBar(
                    fraction: min(1, max(0, Double(verse.ayahNumber) / Double(verse.totalAyahs)))
                )
            }

            Spacer().frame(height: 24)

            // Arabic verse. Renders RTL from the script itself.
            if !verse.arabicText.isEmpty {
                Text(verse.arabicText)
                    .font(QuranTypography.font(
                        baseSize: QuranTypography.readerBaseSize,
                        scale: model.arabicTextScale
                    ))
                    .lineSpacing(QuranTypography.lineSpacing(
                        baseSize: QuranTypography.readerBaseSize,
                        scale: model.arabicTextScale
                    ))
                    .foregroundStyle(Color.cvOnSurface)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .environment(\.layoutDirection, .rightToLeft)
                    .textSelection(.enabled)
                Spacer().frame(height: 28)
            }

            // Previous / Next — centred, directly under the Arabic verse and above
            // the translation, in the normal flow.
            HStack(spacing: 16) {
                CVButton(
                    title: "Previous",
                    systemImage: "arrow.left",
                    style: .outlined,
                    enabled: model.canGoBackward,
                    action: { step(-1) }
                )
                CVButton(
                    title: "Next",
                    systemImage: "arrow.right",
                    style: .outlined,
                    enabled: model.canGoForward,
                    action: { step(1) }
                )
            }

            Spacer().frame(height: 28)

            // English translation — never truncated.
            Text("“\(verse.text)”")
                .font(.system(size: 16, weight: .medium, design: .serif))
                .lineSpacing(13)
                .foregroundStyle(Color.cvOnSurface)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
                .textSelection(.enabled)

            Spacer().frame(height: 32)

            if model.showVerseListen { listenControls }

            // Subtle actions.
            HStack(spacing: 12) {
                CVButton(
                    title: "New Verse",
                    systemImage: "arrow.clockwise",
                    style: .tonal,
                    expand: true,
                    action: {
                        audio.release()
                        Task { await model.refreshVerse() }
                    }
                )
                CVButton(
                    title: "Copy verse",
                    systemImage: "doc.on.doc",
                    style: .outlined,
                    expand: true,
                    action: onCopy
                )
            }
        }
    }

    private var reference: String {
        verse.totalAyahs > 0
            ? "Surah \(verse.surahNumber) · Ayah \(verse.ayahNumber) of \(verse.totalAyahs)"
            : "Surah \(verse.surahNumber) · Ayah \(verse.ayahNumber)"
    }

    /// Leaves the recitation behind with the verse it belonged to. Android
    /// releases the player whenever the verse changes, so Previous/Next/New never
    /// leaves the old ayah playing underneath the one on screen.
    private func step(_ delta: Int32) {
        audio.release()
        Task { await model.stepVerse(delta) }
    }

    // MARK: - Listen (one verse, streamed)

    private var listenControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CVButton(
                    title: listenLabel,
                    systemImage: listenIcon,
                    style: .outlined,
                    enabled: audio.status != .loading,
                    identifier: "quran.listen.action",
                    action: {
                        switch audio.status {
                        case .playing: audio.pause()
                        case .paused: audio.resume()
                        case .ended: audio.restart()
                        // While loading, a tap is inert rather than restarting a
                        // request that is already in flight.
                        case .loading: break
                        case .idle, .failed:
                            if let url = VerseAudio.url(
                                surahNumber: verse.surahNumber,
                                ayahNumber: verse.ayahNumber
                            ) { audio.start(url) }
                        }
                    }
                )
                if audio.status == .playing || audio.status == .paused || audio.status == .ended {
                    CVIconButton(systemName: "arrow.clockwise", label: "Restart", tint: .cvOnSurfaceVariant) {
                        audio.restart()
                    }
                }
            }

            // The seek bar draws itself only once the file is prepared, because a
            // bar that cannot be dragged to a meaningful place is worse than none.
            if audio.isLoaded {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { scrubbing ?? Double(audio.positionMs) },
                            set: { scrubbing = $0 }
                        ),
                        in: 0...Double(max(1, audio.durationMs)),
                        onEditingChanged: { editing in
                            if !editing {
                                if let scrubbing { audio.seek(toMilliseconds: Int(scrubbing)) }
                                scrubbing = nil
                            }
                        }
                    )
                    .tint(.cvPrimary)
                    HStack {
                        Text(VerseAudio.time(Int(scrubbing ?? Double(audio.positionMs))))
                            .font(CVFont.labelSmall)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                        Spacer()
                        Text(VerseAudio.time(audio.durationMs))
                            .font(CVFont.labelSmall)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                }
                .padding(.top, 12)
            }

            if audio.status == .loading {
                Spacer().frame(height: 8)
                Text("Loading recitation…")
                    .font(CVFont.labelSmall)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
            if audio.status == .failed {
                Spacer().frame(height: 8)
                Text("Could not load the recitation. Check your connection and try again.")
                    .font(CVFont.labelSmall)
                    .foregroundStyle(Color.cvError)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 20)
    }

    private var listenLabel: String {
        switch audio.status {
        case .playing: return "Pause"
        case .paused: return "Resume"
        case .ended: return "Replay"
        default: return "Listen"
        }
    }

    private var listenIcon: String {
        switch audio.status {
        case .playing: return "pause.fill"
        case .ended: return "arrow.counterclockwise"
        default: return "play.fill"
        }
    }
}

/// `132 × 3` points, fully rounded: the verse's position inside its surah, drawn
/// from the downloaded edition's ayah count. Not drawn at all when that count is
/// unknown, rather than drawn empty.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cvSurfaceVariant)
                Capsule()
                    .fill(Color.cvPrimary)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(width: 132, height: 3)
    }
}

/// Today's date in the Saudi (Umm al-Qura) calendar, with the small edit target
/// that opens the adjustment sheet — `QuranTab.kt`'s date row.
private struct IslamicDateRow: View {

    let adjustment: Int
    let onEdit: () -> Void

    /// Held as a value that advances on a minute ticker, so a tab left open
    /// across midnight shows the new day without losing the manual adjustment.
    @State private var today = Date()

    var body: some View {
        HStack(spacing: 0) {
            Text(IslamicDate.format(date: today, adjustmentDays: adjustment))
                .font(CVFont.titleSmall)
                .foregroundStyle(Color.cvOnSurfaceVariant)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adjust Islamic date")
        }
        .task {
            // Android's 60-second ticker, for the same reason.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                today = Date()
            }
        }
    }
}

#Preview {
    QuranView()
}
