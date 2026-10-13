import SwiftUI
import SharedKotlin

enum QuranDiscoverySection: String, CaseIterable {
    case search = "Search"
    case surah = "Surah"
    case bookmarks = "Bookmarks"
}

struct QuranLibraryView: View {
    @State private var model: QuranModel
    @State private var section: QuranDiscoverySection
    @State private var query = ""
    @State private var results: [QuranVerse] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var starred = Set<Int32>()
    @State private var pendingRemoval: SurahSummary?
    private let store = QuranStore()

    init(repository: QuranRepository = QuranRepository(), section: QuranDiscoverySection = .surah) {
        _model = State(initialValue: QuranModel(repository: repository))
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(QuranDiscoverySection.allCases, id: \.self) { option in
                    Button { section = option; query = "" } label: {
                        Text(option.rawValue).font(.subheadline.bold())
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(section == option ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                            .background(section == option ? Color.cvPrimaryContainer : Color.cvSurfaceContainer, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("quran.section.\(option.rawValue)")
                        .accessibilityAddTraits(section == option ? .isSelected : [])
                }
            }.padding(.horizontal, 16)
            if section == .bookmarks {
                BookmarksView(repository: model.repository, embedded: true)
            } else {
                CVSearchField(text: $query, prompt: section == .surah ? "Surah name or number" : "Search word or verse (2:255)")
                    .padding(.horizontal, 16)
                content
            }
        }.padding(.top, 8).background(Color.cvBackground)
            .toolbar(.visible, for: .navigationBar)
            .navigationTitle("Quran").navigationBarTitleDisplayMode(.inline)
            .task { await model.load(); starred = Set(store.starredSurahs) }
            .onAppear { starred = Set(store.starredSurahs) }
            .task(id: "\(section.rawValue):\(query)") { await searchVerses() }
            .alert("Remove favorite?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) {
                    if let surah = pendingRemoval { toggleStar(surah) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { Text("Remove \(pendingRemoval?.name ?? "this surah") from bookmarked Surahs?") }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Getting the Quran…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack {
                CVEmptyState(title: "Couldn't load Quran", message: message, symbol: "wifi.exclamationmark")
                Button("Try again") { Task { await model.retry() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let surahs):
            if section == .surah {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(surahs.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query) || Int(query) == $0.number }) { surah in
                            HStack(spacing: 12) {
                                NavigationLink { SurahReaderView(surah: surah, repository: model.repository) } label: {
                                    HStack(spacing: 14) {
                                        Text(String(format: "%02d", surah.number)).font(.subheadline.bold())
                                            .foregroundStyle(Color.cvPrimary).frame(width: 36, height: 36)
                                            .background(Color.cvPrimaryContainer, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(surah.name).font(.headline)
                                            Text(surah.translation).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("quran.surah.\(surah.number)")
                                Button {
                                    if starred.contains(Int32(surah.number)) { pendingRemoval = surah }
                                    else { toggleStar(surah) }
                                } label: {
                                    Image(systemName: starred.contains(Int32(surah.number)) ? "star.fill" : "star")
                                        .font(.title3).foregroundStyle(starred.contains(Int32(surah.number)) ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                                        .frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("\(starred.contains(Int32(surah.number)) ? "Remove favorite" : "Favorite") \(surah.name)")
                            }.padding(14).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CVEmptyState(title: "Search Quran", message: "Enter a word, verse number, or reference such as 2:255.", symbol: "magnifyingglass").frame(maxHeight: .infinity)
            } else if searching {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError {
                CVEmptyState(title: "Search unavailable", message: searchError, symbol: "exclamationmark.triangle").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("\(results.count) results\(results.count == 200 ? " · first 200" : "")").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        ForEach(results, id: \.stableKey) { verse in
                            if let surah = surahs.first(where: { $0.number == Int(verse.surahNumber) }) {
                                NavigationLink { SurahReaderView(surah: surah, repository: model.repository, openAt: verse.ayahNumber) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("\(verse.surahName) · \(verse.surahNumber):\(verse.ayahNumber)").font(.subheadline.bold()).foregroundStyle(Color.cvPrimary)
                                        if !verse.arabicText.isEmpty { Text(verse.arabicText).frame(maxWidth: .infinity, alignment: .trailing) }
                                        Text(verse.text).font(.callout).foregroundStyle(Color.cvOnSurface)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                        .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
                                }.buttonStyle(.plain).accessibilityIdentifier("quran.result.\(verse.surahNumber):\(verse.ayahNumber)")
                            }
                        }
                        if results.isEmpty { CVEmptyState(title: "No results", message: "Try another word or verse reference.", symbol: "magnifyingglass") }
                    }.padding(16)
                }
            }
        }
    }

    private func toggleStar(_ surah: SurahSummary) {
        store.toggleStar(surahNumber: Int32(surah.number))
        starred = Set(store.starredSurahs)
    }

    private func searchVerses() async {
        guard section == .search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; searching = false; return }
        searching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(250))
            let matches = try await model.repository.searchVerses(query)
            try Task.checkCancellation()
            results = matches
            searching = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            searchError = QuranModel.message(for: error)
            searching = false
        }
    }
}

private extension QuranVerse {
    var stableKey: String { "\(surahNumber):\(ayahNumber)" }
}
