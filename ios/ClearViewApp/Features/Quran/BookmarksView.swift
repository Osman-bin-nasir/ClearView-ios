import SwiftUI
import SharedKotlin

/// Saved places: the surahs the reader starred, and the verses they bookmarked.
///    /// Two sections rather than one list, because the two are different intents —
    /// "come back to this surah" and "come back to this verse" — and the Android app
    /// keeps them in two collections for the same reason.
    ///
    /// ## Why the rows push their destination directly
    ///
    /// Every row here is a **view-based** `NavigationLink` that constructs its
    /// `SurahReaderView` itself, rather than a value-based link resolved by a
    /// `navigationDestination(for:)` declared elsewhere in the stack. That is not
    /// a style choice: it is the only form that works from this screen. This screen
    /// is itself pushed by a view-based link, and a `navigationDestination(for:)`
    /// registered on the root's content does not apply to links inside a screen
    /// pushed that way — the destination is looked up along the stack's value path,
    /// and a view-pushed screen is not on it. Every row here was silently inert
    /// until a UI test that asserted on the *navigation bar* (rather than on text
    /// the row also contains) caught it.
    ///
    /// Each row also carries an accessibility **identifier**, which is not
    /// decoration either: the surah list is still in the hierarchy behind this
    /// pushed screen, so both screens contain a static text reading "Al-Faatiha". A
    /// test (or VoiceOver user) matching on the label alone cannot tell them apart,
    /// and an automated tap on the wrong one is silently a no-op. Identifiers are
    /// unique across the whole hierarchy, so they can.
    struct BookmarksView: View {

    @State private var model: BookmarksModel
    @State private var query = ""
    @State private var pendingVerse: BookmarksModel.BookmarkedVerse?
    private let embedded: Bool

    init(repository: QuranRepository, embedded: Bool = false) {
        _model = State(initialValue: BookmarksModel(repository: repository))
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 12) {
            CVSearchField(text: $query, prompt: "Search bookmarks", identifier: "bookmarks.search").padding(.horizontal, 16)
            content
        }
            .background(Color.cvBackground)
            .navigationTitle(embedded ? "Quran" : "Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            // `onAppear` rather than `task`: the reader can change a bookmark and
            // then pop back here, and the list has to include it. `task` runs once
            // per view identity and would show a stale list for the session.
            .onAppear { Task { await model.reload() } }
            .alert("Remove bookmark?", isPresented: Binding(get: { pendingVerse != nil }, set: { if !$0 { pendingVerse = nil } })) {
                Button("Remove", role: .destructive) {
                    if let verse = pendingVerse { Task { await model.remove(verse) } }
                    pendingVerse = nil
                }
                Button("Cancel", role: .cancel) { pendingVerse = nil }
            } message: { Text("Remove this verse from your bookmarks?") }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cvBackground)

        case .ready(let starred, let verses):
            let matchingSurahs = starred.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query) || Int(query) == $0.number }
            let matchingVerses = verses.filter { query.isEmpty || $0.surah.name.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) || $0.id.contains(query) }
            if starred.isEmpty && verses.isEmpty {
                emptyState
            } else if matchingSurahs.isEmpty && matchingVerses.isEmpty {
                CVEmptyState(title: "No bookmarks found", message: "Try another Surah name, word, or verse reference.", symbol: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    if !matchingSurahs.isEmpty {
                        Section("Bookmarked Surahs") {
                            ForEach(matchingSurahs) { surah in
                                // No `openAt`: a starred surah means "read this
                                // surah", so the reader restores the saved reading
                                // position — which is what a reader wants.
                                NavigationLink {
                                    SurahReaderView(surah: surah, repository: model.repository)
                                } label: {
                                    StarredSurahRow(surah: surah)
                                }
                                .accessibilityIdentifier(Self.starredRowIdentifier(surah.number))
                                .listRowBackground(Color.cvSurfaceContainer)
                            }
                        }
                    }

                    if !matchingVerses.isEmpty {
                        Section("Bookmarked verses") {
                            ForEach(matchingVerses) { verse in
                                // `openAt`: a bookmarked verse means "take me to
                                // *this* verse", which is a different intent from
                                // "read this surah" — and the only reason the
                                // reader takes an explicit target at all.
                                NavigationLink {
                                    SurahReaderView(
                                        surah: verse.surah,
                                        repository: model.repository,
                                        openAt: verse.ayahNumber
                                    )
                                } label: {
                                    BookmarkedVerseRow(verse: verse)
                                }
                                .accessibilityIdentifier(Self.verseRowIdentifier(verse.id))
                                .listRowBackground(Color.cvSurfaceContainer)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingVerse = verse
                                    } label: {
                                        Label("Remove", systemImage: "bookmark.slash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.cvBackground)
            }

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

    /// Says what to do about it, not just that there is nothing here — an empty
    /// screen that only says "none" leaves a reader wondering whether saving is
    /// even possible.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 36))
                .foregroundStyle(Color.cvOnSurfaceVariant)
            Text("Nothing saved yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.cvOnSurface)
            Text("Tap the bookmark on any ayah to save it, or the star in a surah's toolbar to save the whole surah.")
                .font(.footnote)
                .foregroundStyle(Color.cvOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cvBackground)
    }
}

extension BookmarksView {
    /// Stable identifiers for the rows, so a UI test addresses the row itself
    /// rather than the text inside it.
    static func starredRowIdentifier(_ surahNumber: Int) -> String { "bookmarks.starred.\(surahNumber)" }

    static func verseRowIdentifier(_ verseID: String) -> String { "bookmarks.verse.\(verseID)" }
}

private struct StarredSurahRow: View {
    let surah: SurahSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.footnote)
                .foregroundStyle(Color.cvPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(surah.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.cvOnSurface)
                Text(surah.translation)
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BookmarkedVerseRow: View {
    let verse: BookmarksModel.BookmarkedVerse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verse.surah.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.cvPrimary)

            Text(verse.text)
                .font(.callout)
                .foregroundStyle(Color.cvOnSurface)
                // Two lines, so the row stays scannable when the verse is long —
                // the full text is one tap away in the reader.
                .lineLimit(2)

            Text("\(verse.surah.number):\(verse.ayahNumber)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.cvOnSurfaceVariant)
        }
        .padding(.vertical, 4)
    }
}
