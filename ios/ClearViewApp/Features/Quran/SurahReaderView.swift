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

    /// The id of the view at the top of the scroll view — the header (id 0) or an
    /// ayah's number. `scrollPosition(id:)` keeps this up to date, which is how
    /// the reader notices where it is; `ScrollViewReader` drives it back, which is
    /// how it opens where it left off.
    @State private var topItem: Int32?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    SurahHeader(surah: surah)
                        // Item 0 is the header — the top of the surah, which the
                        // shared reading-position rule already reads as "save
                        // nothing".
                        .id(Int32(0))
                    ForEach(ayahs) { ayah in
                        AyahCard(
                            ayah: ayah,
                            arabicTextScale: arabicTextScale,
                            isBookmarked: isBookmarked(ayah.verse.ayahNumber),
                            onToggleBookmark: { onToggleBookmark(ayah.verse.ayahNumber) }
                        )
                        .id(ayah.id)
                    }
                }
                .scrollTargetLayout()
                .padding()
            }
            .scrollPosition(id: $topItem)
            .background(Color.cvBackground)
            .task {
                guard let target = restoreTo else { return }
                // `proxy.scrollTo` rather than writing `topItem`, and one turn of
                // the runloop later than the rows are created. `scrollTo` walks
                // the LazyVStack to an id that may be far outside the viewport —
                // which a binding write cannot do, because the target view does
                // not exist yet for it to scroll to.
                await Task.yield()
                proxy.scrollTo(target, anchor: .top)
            }
            .onChange(of: topItem) { _, newValue in
                // nil means the scroll view has not resolved a position yet, not
                // that the reader is at the top — so it is not saved.
                guard let newValue else { return }
                onTopAyahChanged(newValue)
            }
        }
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
