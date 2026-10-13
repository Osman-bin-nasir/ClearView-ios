import SwiftUI
import SharedKotlin

/// The surah list — the "Surah" view of Android's Quran screen
/// (`quran/ui/QuranSearchScreen.kt`'s browse tab).
///
/// The list is the real downloaded edition, parsed by the **shared Kotlin
/// module** (`QuranJsonParser`), so the names, meanings and ayah counts are the
/// same on both platforms and nothing here can drift from what Android shows.
///
/// Opened from the magnifier in the Quran tab's bar. Android's screen is one
/// surface with three views — search by words, browse surahs, and the bookmarks
/// the reader kept — and this is the middle one; the other two arrive with the
/// rest of that screen.
struct QuranLibraryView: View {

    @State private var model = QuranModel()
    @State private var search = ""

    var body: some View {
        Group {
            content
                .background(Color.cvBackground)
                .navigationTitle("Quran")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Surah name or number")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            BookmarksView(repository: model.repository)
                        } label: {
                            Image(systemName: "bookmark")
                        }
                        .disabled(!model.isReady)
                        .accessibilityLabel("Bookmarks")
                    }
                }
                // `.task` runs on appear and is cancelled with the view, so a
                // download in flight when the reader leaves is torn down rather
                // than left running against a view nobody is looking at.
                .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(.cvPrimary)
                Text("Getting the Quran…")
                    .font(.footnote)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)

        case .ready(let surahs):
            List(matching(surahs)) { surah in
                NavigationLink {
                    SurahReaderView(surah: surah, repository: model.repository)
                } label: {
                    SurahRow(surah: surah, scale: model.arabicTextScale)
                }
                .listRowBackground(Color.cvBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

        case .failed(let message):
            // Retry is offered because both realistic failures — offline, and a
            // body that would not parse — are worth trying again, and the
            // alternative is an app that stays broken until it is relaunched.
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.cvError)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.cvOnSurface)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                CVButton(title: "Try again", style: .filled) {
                    Task { await model.retry() }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)
        }
    }

    /// Android's surah search matches on the name, the meaning, or the number —
    /// so "36", "ya-seen" and "Ya Sin" all find the same surah.
    private func matching(_ surahs: [SurahSummary]) -> [SurahSummary] {
        let query = search.trimmed
        guard !query.isEmpty else { return surahs }
        return surahs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.translation.localizedCaseInsensitiveContains(query)
                || String($0.number) == query
        }
    }
}

/// One row of the surah list: number, transliterated name, its meaning, and how
/// many ayahs it holds — the shape Android's browse list draws.
private struct SurahRow: View {
    let surah: SurahSummary
    let scale: Double

    var body: some View {
        HStack(spacing: 14) {
            // The number in a rounded badge, the way the Android list and the
            // printed mushaf both present it.
            Text("\(surah.number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.cvPrimary)
                .frame(width: 34, height: 34)
                .background(Color.cvPrimaryContainer, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(surah.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.cvOnSurface)
                Text(surah.translation)
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }

            Spacer(minLength: 8)

            if surah.ayahCount > 0 {
                Text("\(surah.ayahCount) ayahs")
                    .font(.caption2)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { QuranLibraryView() }
}
