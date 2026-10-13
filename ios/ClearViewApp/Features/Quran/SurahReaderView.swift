import SwiftUI
import SharedKotlin

/// One surah, ayah by ayah: the Arabic (IndoPak) above the English.
///
/// This is the reading surface, so it makes two layout choices worth stating:
///
///  - The Arabic is a **separate paragraph** above the translation rather than
///    inline beside it. Mixed-script inline runs are what force a reader to
///    hunt for where the Arabic ends, and no line-height setting fixes that.
///  - The Arabic is never the only thing on screen. The English is always
///    present, so a missing or not-yet-cached Arabic edition degrades to a
///    readable English reader instead of a blank page.
struct SurahReaderView: View {

    @State private var model: SurahReaderModel

    init(surah: SurahSummary, repository: QuranRepository, openAt: Int32? = nil) {
        _model = State(
            initialValue: SurahReaderModel(
                surah: surah,
                repository: repository,
                openAt: openAt
            )
        )
    }

    var body: some View {
        content
            .background(Color.cvBackground)
            // The surah's position and meaning in the title area, where the
            // Android toolbar puts them too.
            .navigationTitle(model.surah.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Text size before the star, so the destructive-ish action
                    // (unstarring) is not the control nearest the edge a thumb
                    // reaches for.
                    Button {
                        model.decreaseArabicScale()
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .disabled(!model.canDecreaseArabicScale)
                    .accessibilityLabel("Smaller Arabic text")
                    .accessibilityIdentifier("reader.text.smaller")

                    Button {
                        model.increaseArabicScale()
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .disabled(!model.canIncreaseArabicScale)
                    .accessibilityLabel("Larger Arabic text")
                    .accessibilityIdentifier("reader.text.larger")

                    Button {
                        model.toggleStar()
                    } label: {
                        Image(systemName: model.isStarred ? "star.fill" : "star")
                            .foregroundStyle(model.isStarred ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                    }
                    // Named for what it is, not for its icon: VoiceOver announcing
                    // "star" cannot tell a reader whether tapping will add one or
                    // remove the one they already have.
                    .accessibilityLabel(model.isStarred ? "Remove surah star" : "Star this surah")
                }
            }
            .task { await model.load() }
            // On EVERY appearance, not just the first: SwiftUI may hand this screen
            // back with its state intact when the same surah is opened again in the
            // same session, and the reading position it read then is not the one the
            // store holds now.
            .onAppear { model.refreshRestorePosition() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cvBackground)

        case .ready(let ayahs):
            ReaderContent(
                surah: model.surah,
                ayahs: ayahs,
                restoreTo: model.restorePosition,
                arabicTextScale: model.arabicTextScale,
                isBookmarked: { model.isBookmarked(ayahNumber: $0) },
                onToggleBookmark: { model.toggleBookmark(ayahNumber: $0) },
                onTopAyahChanged: { model.rememberTopAyah($0) }
            )

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.cvError)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.cvOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)
        }
    }
}

/// The scrollable body of the reader: the header, then every ayah.
///
/// Split out of `SurahReaderView` so it is only ever constructed when the verses
/// exist. That is what makes restoring the reading position reliable: the scroll
/// target is a ROW, and a row only exists once there are ayahs to build. Ran from
/// the state-switching view, the restore would be asked for in the same turn that
/// the content is created — before SwiftUI has laid a single row out — and the
/// request would be dropped silently, which is exactly what happened the first
/// time (a UI test caught it: the position was saved as "2:14" and the reader
/// still opened at "2:1").
private struct ReaderContent: View {

    let surah: SurahSummary
    let ayahs: [SurahReaderModel.Ayah]
    let restoreTo: Int32?
    let arabicTextScale: Double
    let isBookmarked: (Int32) -> Bool
    let onToggleBookmark: (Int32) -> Void
    let onTopAyahChanged: (Int32) -> Void

    /// The rows currently on screen, so the reader can tell where it is. The
    /// header is 0 and an ayah is its own number.
    ///
    /// Tracked from the rows' own appear/disappear rather than from
    /// `scrollPosition(id:)`, which only works inside a `ScrollView`. It is a
    /// `List` here deliberately — see `body`.
    @State private var visibleRows: Set<Int32> = []

    /// The pending "the reader is at the top of the surah" write. Held so it can be
    /// withdrawn — by a scroll away from the top, or by the page closing.
    @State private var pendingClear: Task<Void, Never>?

    /// Whether the scroll view is genuinely at its very top.
    ///
    /// Read from the scroll geometry rather than guessed from which rows are on
    /// screen, because that is the one signal a page being taken apart does not
    /// fake: removing the reader collapses its rows and reports the top of the
    /// surah through them, but it stops reporting a scroll position altogether.
    @State private var isAtScrollTop = true

    /// The row at the top of the page: the smallest visible one that is not the
    /// header. A nil answer means nothing has been laid out yet, which is not the
    /// same as "the reader is at the top" and is not saved.
    private var topRow: Int32? {
        visibleRows.filter { $0 > 0 }.min()
    }

    var body: some View {
        // A `List`, not a `ScrollView` + `LazyVStack`.
        //
        // The reader has to open where it was left, and that is a scroll to an ayah
        // that is usually nowhere near the top of the surah. A lazy stack cannot be
        // scrolled to a row it has never built: `scrollTo` and even the
        // `scrollPosition(id:)` binding were both dropped silently for a target
        // twenty rows down, so a reader who left Al-Baqara at 2:13 reopened it at
        // 2:1 — with the position saved correctly in the store the whole time, which
        // is what proved the fault was the scroll rather than the record. `List` is
        // backed by a real table view, whose `scrollTo` reaches any row, realized or
        // not, and it is what Android's `LazyColumn.scrollToItem` does for the same
        // reason.
        ScrollViewReader { proxy in
            List {
                SurahHeader(surah: surah)
                    // Item 0 is the header — the top of the surah, which the shared
                    // reading-position rule already reads as "save nothing".
                    .id(Int32(0))
                    .listRowModifiers()
                    .onAppear { visibleRows.insert(0) }
                    .onDisappear { visibleRows.remove(0) }

                ForEach(ayahs) { ayah in
                    AyahCard(
                        ayah: ayah,
                        arabicTextScale: arabicTextScale,
                        isBookmarked: isBookmarked(ayah.verse.ayahNumber),
                        onToggleBookmark: { onToggleBookmark(ayah.verse.ayahNumber) }
                    )
                    .id(ayah.id)
                    .listRowModifiers()
                    .onAppear { visibleRows.insert(ayah.id) }
                    .onDisappear { visibleRows.remove(ayah.id) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(Color.cvBackground)
            // Keyed by the target, so a position re-read on a later appearance
            // re-anchors the page instead of being ignored because this task had
            // already run once.
            .task(id: restoreTo) {
                guard let target = restoreTo else { return }
                // One turn of the runloop later than the rows exist, and repeated
                // because the first request can still land before the list has laid
                // its rows out. A reader who has scrolled in the meantime simply
                // re-anchors where they asked to be.
                for attempt in 0..<5 {
                    if attempt > 0 {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            // Saved as the reader scrolls, with two different rules — because
            // "where I am" and "I am back at the top" are not equally trustworthy.
            //
            // A scrolled-to ayah (2 or later) IS the reader's position, nothing else
            // produces it, and it is saved the moment it becomes the top row.
            //
            // "The top of the surah" is saved only if the reader stays there. That
            // is the one answer the page's own teardown also produces: removing the
            // reader collapses the rows and momentarily reports the top of the
            // surah, and saved, that reads as "clear the saved position" — which is
            // how a reader who left at 2:12 came back to 2:1. A half-second of
            // patience costs a reader nothing (they are looking at the top of the
            // surah either way) and the pending write is cancelled if the reader
            // scrolls on or closes the page, which is exactly what a teardown is.
            .onChange(of: visibleRows) { _, rows in
                guard let top = rows.filter({ $0 > 0 }).min() else { return }
                if top >= 2 {
                    pendingClear?.cancel()
                    onTopAyahChanged(top)
                } else if isAtScrollTop {
                    pendingClear?.cancel()
                    pendingClear = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, isAtScrollTop else { return }
                        onTopAyahChanged(top)
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= 1
            } action: { _, atTop in
                isAtScrollTop = atTop
                // Arriving at the top by scrolling is the reader saying "start me
                // here next time", so it is recorded once the page settles.
                if atTop, let top = visibleRows.filter({ $0 > 0 }).min() {
                    pendingClear?.cancel()
                    pendingClear = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, isAtScrollTop else { return }
                        onTopAyahChanged(top)
                    }
                }
            }
            .onDisappear { pendingClear?.cancel() }
        }
    }
}

private extension View {
    /// The list-row chrome a reader should not see: no separator, no inset, no
    /// background of its own, so a row of scripture looks exactly as it did in the
    /// scroll view this replaced.
    func listRowModifiers() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .padding(.horizontal)
            .padding(.vertical, 6)
    }
}

/// The surah's number, name, meaning and length, once, above the verses.
private struct SurahHeader: View {
    let surah: SurahSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(surah.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.cvPrimary)
            Text(surah.translation)
                .font(.subheadline)
                .foregroundStyle(Color.cvOnSurfaceVariant)
            Text("Surah \(surah.number) · \(surah.ayahCount) ayahs")
                .font(.caption)
                .foregroundStyle(Color.cvOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// A single ayah: Arabic, then English, then the ayah's position and its
/// bookmark control.
private struct AyahCard: View {
    /// The reader's chosen size for the Arabic alone. The English and the chrome
    /// stay fixed: this scales the scripture, not the app — which is what the
    /// Android reader does, and what a reader adjusting it is asking for.
    private static let baseArabicSize: Double = 24

    let ayah: SurahReaderModel.Ayah
    let arabicTextScale: Double
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ayah.arabic.isEmpty {
                Text(ayah.arabic)
                    .font(.system(size: Self.baseArabicSize * arabicTextScale))
                    // Line spacing scales with the type, so a larger size does not
                    // crowd the marks into the line below.
                    .lineSpacing(10 * arabicTextScale)
                    .multilineTextAlignment(.trailing)
                    // Right-to-left, explicitly. Leaving this to the system
                    // guessing from the Unicode bidi ranges works for a clean
                    // verse but flips odd leading marks the wrong way.
                    .environment(\.layoutDirection, .rightToLeft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(Color.cvOnSurface)
            }

            Text(ayah.verse.text)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(Color.cvOnSurface)

            HStack {
                Text("\(ayah.verse.surahNumber):\(ayah.verse.ayahNumber)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.cvPrimary)

                Spacer()

                // A button, not a swipe action: a bookmark is the thing a reader
                // reaches for mid-verse, and a gesture that needs discovering is
                // the wrong shape for it. The tap target is padded out to a full
                // 44 points, which is the size the system considers comfortable.
                Button(action: onToggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.footnote)
                        .foregroundStyle(isBookmarked ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isBookmarked
                        ? "Remove bookmark from ayah \(ayah.verse.ayahNumber)"
                        : "Bookmark ayah \(ayah.verse.ayahNumber)"
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cvOutlineVariant, lineWidth: 1)
        )
    }
}
