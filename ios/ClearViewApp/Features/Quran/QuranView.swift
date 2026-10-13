import SwiftUI
import SharedKotlin

/// The Quran tab: the 114 surahs.
///
/// The list is the real downloaded edition, parsed by the **shared Kotlin
/// module** (`QuranJsonParser`) — the same code the Android app's reader uses.
/// The surah names, the translations and the ayah counts all come from the
/// parsed data, so nothing here can drift from what the other platform shows.
///
/// The tab is a list rather than a single "verse of the day", because that is
/// what the Android tab opens onto; the reminder widget — which *is* a single
/// verse — is a separate surface, and it reuses this same repository.
struct QuranLibraryView: View {

    @State private var model = QuranModel()
    @State private var search = ""

    var body: some View {
        Group {
            content
                .background(Color.cvBackground)
                .navigationTitle("Quran")
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
                // download in flight when the user switches tabs is torn down
                // rather than left running against a view nobody is looking at.
                .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Getting the Quran…")
                    .font(.footnote)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)

        case .ready(let surahs):
            VStack(spacing: 0) {
                // The reminder sits above the list, outside it: it is not a 115th
                // surah row, and giving it a list row would put it in the same
                // scroll as the surahs and in the same selection space.
                if let verse = model.currentVerse, let surah = model.currentVerseSurah {
                    // The link and the refresh control are SIBLINGS, not nested.
                    // A `Button` inside a `NavigationLink`'s label swallows the tap,
                    // which made this card completely inert when the refresh button
                    // lived in its header row — the link never fired at all. Only a
                    // UI test asserting on the back button rather than on the
                    // card's own text caught it; the text is still in the hierarchy,
                    // so a label match passed while nothing navigated.
                    HStack(alignment: .top, spacing: 8) {
                        NavigationLink {
                            SurahReaderView(
                                surah: surah,
                                repository: model.repository,
                                openAt: verse.ayahNumber
                            )
                        } label: {
                            ReminderVerseBody(verse: verse)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("quran.reminder")

                        // A column of controls beside the verse, all siblings of
                        // the link — see the note above on why none may nest inside
                        // it.
                        VStack(spacing: 0) {
                            Button {
                                Task { await model.stepVerse(-1) }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.footnote)
                                    .foregroundStyle(model.canGoBackward ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.4))
                                    .frame(width: 44, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canGoBackward)
                            .accessibilityLabel("Previous verse")
                            .accessibilityIdentifier("quran.reminder.previous")

                            Button {
                                Task { await model.stepVerse(1) }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.footnote)
                                    .foregroundStyle(model.canGoForward ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.4))
                                    .frame(width: 44, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canGoForward)
                            .accessibilityLabel("Next verse")
                            .accessibilityIdentifier("quran.reminder.next")

                            Button {
                                Task { await model.refreshVerse() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.footnote)
                                    .foregroundStyle(Color.cvPrimary)
                                    .frame(width: 44, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show another verse")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cvSurfaceContainerLow)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.cvOutlineVariant).frame(height: 1)
                    }
                } else if let message = model.verseError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.cvError)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                List(surahs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.translation.localizedCaseInsensitiveContains(search) || String($0.number) == search }) { surah in
                    NavigationLink(value: surah) {
                        SurahRow(surah: surah)
                    }
                    .listRowBackground(Color.cvSurface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Color.cvBackground)
            // Registered here rather than on a view further up, because a
            // `navigationDestination` only applies to links in the stack's own
            // value path — the Bookmarks screen, which is pushed by a view-based
            // link, builds its reader links directly instead.
            .navigationDestination(for: SurahSummary.self) { surah in
                SurahReaderView(surah: surah, repository: model.repository)
            }

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
                Button("Try again") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cvPrimary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cvBackground)
        }
    }
}

/// The reminder's contents: which surah and ayah, then the verse itself.
///
/// Contains no controls on purpose — it is the `NavigationLink`'s label, and a
/// button in here would swallow the link's tap (see `QuranView`).
private struct ReminderVerseBody: View {
    let verse: QuranVerse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verse.surahName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.cvPrimary)
                Spacer()
                Text("\(verse.surahNumber):\(verse.ayahNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    // Identified so a UI test can read the position off the card and
                    // then check the reader opens *there* — as a label it is just
                    // text among text.
                    .accessibilityIdentifier("quran.reminder.position")
            }

            if !verse.arabicText.isEmpty {
                Text(verse.arabicText)
                    .font(.system(size: 20))
                    .lineSpacing(8)
                    .multilineTextAlignment(.trailing)
                    .environment(\.layoutDirection, .rightToLeft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(Color.cvOnSurface)
            }

            Text(verse.text)
                .font(.callout)
                .foregroundStyle(Color.cvOnSurface)
                // Bounded so the reminder stays a reminder: a long ayah must not
                // push the surah list off the first screen.
                .lineLimit(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of the surah list: number, transliterated name, its meaning, and how
/// many ayahs it holds.
private struct SurahRow: View {
    let surah: SurahSummary

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
    QuranLibraryView()
}
