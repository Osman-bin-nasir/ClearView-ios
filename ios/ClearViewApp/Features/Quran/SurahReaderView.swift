import SwiftUI
import SharedKotlin

/// A continuous Quran reading page with controls kept above the scripture.
struct SurahReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SurahReaderModel
    @State private var autoScroll = QuranReaderAutoScroll()
    @State private var audio = VerseAudioPlayer()
    @State private var showSearch = false
    @State private var showTextSize = false
    /// Whether the surah's identity block and the reading-mode switch are showing.
    ///
    /// Android's `readerHeaderOpen` (§2), and open by default for the same reason:
    /// opening a surah you have not opened before with its name and its length
    /// already folded away is being dropped into the middle of something.
    @State private var headerOpen = true
    @State private var selectedAyah: Int32?
    @State private var listeningAyah: Int32?
    @State private var copiedAyah: Int32?
    @FocusState private var searchFocused: Bool

    init(surah: SurahSummary, repository: QuranRepository, openAt: Int32? = nil) {
        _model = State(initialValue: SurahReaderModel(surah: surah, repository: repository, openAt: openAt))
    }

    var body: some View {
        VStack(spacing: 0) {
            if headerOpen { surahBanner }
            if showSearch { searchField }
            if showTextSize { textSizeControl }
            content
        }
        .background(Color.cvBackground)
        .foregroundStyle(Color.cvOnSurface)
        .tint(Color.cvPrimary)
        .preferredColorScheme(.dark)
        .navigationTitle(model.surah.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbarBackground(Color.cvBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // ── The reader's top bar (§1) ──
        //
        // The back arrow and the surah's name are the navigation bar's own, and
        // the four controls beside them are the reader's: fold the identity block
        // away, search the surah, size the text, start it scrolling. Android draws
        // this row itself because it has no navigation bar to put it in; on iOS the
        // bar is already there with the arrow and the name, so the same row is the
        // same row — one bar, not a bar plus a strip under it.
        //
        // Order matters and follows Android: the fold comes BEFORE search, because
        // a bigger page is the first thing a reader wants in a long surah and search
        // is what they want in a specific one.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back").accessibilityIdentifier("BackButton")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                barControl(
                    headerOpen ? "chevron.up" : "chevron.down",
                    label: headerOpen ? "Hide surah details" : "Show surah details",
                    id: "reader.headerToggle",
                    // Accent-tinted while folded, so the icon says which state a
                    // second tap will leave — Android's `readerHeaderOpen` tint.
                    active: !headerOpen
                ) { autoScroll.pause(); headerOpen.toggle() }

                barControl("magnifyingglass", label: "Search verses", id: "reader.search",
                           active: showSearch) {
                    autoScroll.pause()
                    showSearch.toggle()
                    if showSearch { showTextSize = false }
                    else { model.search = ""; searchFocused = false }
                }

                barControl("textformat.size", label: "Text size", id: "reader.textSize",
                           active: showTextSize) {
                    autoScroll.pause()
                    searchFocused = false
                    showTextSize.toggle()
                }

                // Hands-free reading: a MENU of paces, not a row of buttons held
                // open under the bar (Android's `DropdownMenu`, §1). The row cost a
                // line of the page for the whole time it was showing, and the reader
                // picks a pace once and then reads for an hour — so the choices
                // appear when asked for and leave when one is chosen, which a menu
                // does by itself.
                //
                // Off is a row here rather than a separate switch, the way Android
                // lists it among the paces, and the check mark is the same control
                // that changes it — so "what is the page doing" and "make it do
                // something else" are one tap apart rather than two screens apart.
                Menu {
                    Section("Scroll speed") {
                        Button {
                            searchFocused = false
                            autoScroll.pause()
                        } label: {
                            if autoScroll.isRunning { Text("Off") }
                            else { Label("Off", systemImage: "checkmark") }
                        }
                        .accessibilityIdentifier("reader.speed.Off")

                        ForEach(QuranAutoScrollSpeed.allCases) { speed in
                            Button {
                                searchFocused = false
                                setScrollSpeed(speed)
                            } label: {
                                if autoScroll.isRunning && autoScroll.speed == speed {
                                    Label(speed.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(speed.rawValue)
                                }
                            }
                            .accessibilityIdentifier("reader.speed.\(speed.rawValue)")
                        }
                    }
                } label: {
                    Image(systemName: "speedometer").font(.system(size: 17))
                        .foregroundStyle(autoScroll.isRunning ? Color.cvPrimary : Color.cvOnSurface)
                }
                .accessibilityLabel("Auto-scroll speed")
                .accessibilityIdentifier("reader.autoScroll")
                .accessibilityValue(autoScroll.isRunning ? "\(autoScroll.speed.rawValue), scrolling" : "Paused")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if listeningAyah != nil { audioControls }
        }
        .task { await model.load() }
        .onAppear { model.refreshRestorePosition() }
        .onDisappear {
            autoScroll.pause()
            audio.release()
            listeningAyah = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                autoScroll.pause()
                audio.pause()
                if audio.status == .loading {
                    audio.release()
                    listeningAyah = nil
                }
            }
        }
        .onChange(of: model.search) { _, query in
            autoScroll.pause()
            selectedAyah = nil
            if query.isEmpty { model.refreshRestorePosition() }
        }
    }

    /// The surah's identity and the reading-mode switch, pinned above the text.
    ///
    /// Android's `SurahBanner`, control for control (§2): the name, its meaning,
    /// the surah's number and how many ayahs it holds, and then the two ways it
    /// can be read as two buttons rather than as one that toggles. A toggle has to
    /// be read before it is understood, and which text is on screen is the one
    /// thing here a reader must never have to work out.
    ///
    /// It is pinned rather than scrolled, which is why the fold control in the top
    /// bar exists: this block costs its height on every one of a read that may be
    /// a hundred screenfuls. The surah's name stays in the top bar while it is
    /// folded, so folding gives up height and not the sense of where you are.
    private var surahBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(model.surah.name).font(.title3.weight(.bold))
                Button { autoScroll.pause(); model.toggleStar() } label: {
                    Image(systemName: model.isStarred ? "star.fill" : "star").font(.system(size: 15))
                }
                .accessibilityLabel(model.isStarred ? "Remove surah star" : "Star this surah")
                .accessibilityIdentifier("reader.star")
                Spacer(minLength: 0)
            }
            if !model.surah.translation.isEmpty {
                Text(model.surah.translation)
                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            Text("Surah \(model.surah.number) · \(model.surah.ayahCount) ayahs")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            HStack(spacing: 8) {
                modeButton(.arabic)
                modeButton(.english)
            }.padding(.top, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.cvOnSurface)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.cvSurfaceContainerLow)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.cvOutlineVariant.opacity(0.4)).frame(height: 0.5) }
        .accessibilityIdentifier("reader.banner")
    }

    /// One of the two reading modes — Android's `QuranSegment`.
    ///
    /// The selected one is filled with the accent rather than merely bolded: it is
    /// a statement about what the page below is, and it has to be unmistakable at
    /// a glance from the text it describes.
    private func modeButton(_ mode: QuranReadingMode) -> some View {
        let selected = model.language == mode
        return Button {
            autoScroll.pause()
            model.language = mode
            selectedAyah = nil
        } label: {
            Text(mode == .arabic ? "Arabic" : "English")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(selected ? Color.cvOnPrimary : Color.cvOnSurfaceVariant)
                .background(selected ? Color.cvPrimary : Color.cvSurfaceContainerHigh, in: Capsule())
        }
        .accessibilityIdentifier(mode == .arabic ? "reader.mode.arabic" : "reader.mode.english")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    /// One control in the reader's top bar. Tinted with the accent while it is
    /// doing something, so a control that is on never has to be guessed at.
    private func barControl(_ symbol: String, label: String, id: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17))
                .foregroundStyle(active ? Color.cvPrimary : Color.cvOnSurface)
        }.accessibilityLabel(label).accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            ReaderContent(
                ayahs: model.filteredAyahs, basmala: model.basmala,
                restoreTo: model.restorePosition, search: model.search,
                arabicTextScale: model.arabicTextScale, language: model.language,
                selectedAyah: selectedAyah, copiedAyah: copiedAyah, autoScroll: autoScroll,
                isBookmarked: { model.isBookmarked(ayahNumber: $0) },
                onToggleBookmark: { model.toggleBookmark(ayahNumber: $0) },
                onTopAyahChanged: { model.rememberTopAyah($0) },
                onSelect: {
                    autoScroll.pause()
                    searchFocused = false
                    copiedAyah = nil
                    selectedAyah = selectedAyah == $0 ? nil : $0
                },
                onCopy: {
                    UIPasteboard.general.string = model.copyText(for: $0)
                    copiedAyah = $0.id
                },
                onListen: { listen(to: $0) }
            )
        case .failed(let message):
            CVEmptyState(title: "Unable to load this surah", message: message, symbol: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.cvOnSurfaceVariant)
            TextField("Search Arabic, English, or ayah", text: $model.search)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .focused($searchFocused).submitLabel(.search)
                .accessibilityIdentifier("reader.search.field")
                .onSubmit { searchFocused = false }
            Button {
                model.search = ""
                showSearch = false
                searchFocused = false
            } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44) }
                .accessibilityLabel("Close verse search")
        }
        .font(.subheadline).padding(.horizontal, 16)
        .background(Color.cvSurfaceContainer)
        .onAppear { searchFocused = true }
    }

    private var textSizeControl: some View {
        HStack(spacing: 12) {
            Button { autoScroll.pause(); model.decreaseArabicScale() } label: {
                Image(systemName: "textformat.size.smaller").frame(width: 32, height: 44)
            }
            .disabled(!model.canDecreaseArabicScale)
            .accessibilityLabel("Smaller text").accessibilityIdentifier("reader.text.smaller")
            Slider(value: Binding(get: { model.arabicTextScale }, set: {
                autoScroll.pause()
                model.setArabicTextScale($0)
            }), in: QuranStore.arabicTextScaleRange, step: 0.05)
                .accessibilityLabel("Reading text size")
                .accessibilityValue("\(Int(model.arabicTextScale * 100)) percent")
                .accessibilityIdentifier("reader.text.slider")
            Button { autoScroll.pause(); model.increaseArabicScale() } label: {
                Image(systemName: "textformat.size.larger").frame(width: 32, height: 44)
            }
            .disabled(!model.canIncreaseArabicScale)
            .accessibilityLabel("Larger text").accessibilityIdentifier("reader.text.larger")
        }.buttonStyle(.plain).padding(.horizontal, 16).background(Color.cvSurfaceContainer)
    }

    /// Starts the page moving at `speed`, from the reader's own top bar menu.
    ///
    /// `pause()` and `start()` on the driver are not symmetric with `speed`: the
    /// pace is a property of the driver that outlives a run, so choosing a pace is
    /// always "set it, then start" — and the menu's check mark reads that same
    /// property, which is why the two cannot drift apart.
    private func setScrollSpeed(_ speed: QuranAutoScrollSpeed) {
        autoScroll.speed = speed
        autoScroll.start()
    }

    private func listen(to ayah: SurahReaderModel.Ayah) {
        autoScroll.pause()
        guard let url = VerseAudio.url(surahNumber: ayah.verse.surahNumber, ayahNumber: ayah.id) else { return }
        listeningAyah = ayah.id
        audio.start(url)
    }

    private var audioControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones").foregroundStyle(Color.cvPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ayah \(model.surah.number):\(listeningAyah ?? 1)").font(.subheadline.weight(.semibold))
                Text(audio.status == .failed ? "Could not play recitation. Tap to retry." :
                     audio.status == .loading ? "Loading recitation…" : "Mishary Alafasy")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if audio.status == .loading { ProgressView() }
            else {
                Button {
                    switch audio.status {
                    case .playing: audio.pause()
                    case .paused: audio.resume()
                    case .ended: audio.restart()
                    default:
                        if let ayah = model.ayahs.first(where: { $0.id == listeningAyah }) { listen(to: ayah) }
                    }
                } label: {
                    Image(systemName: audio.status == .playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(audio.status == .playing ? "Pause recitation" : "Play recitation")
            }
            Button {
                audio.release()
                listeningAyah = nil
            } label: { Image(systemName: "xmark").frame(width: 36, height: 44) }
                .accessibilityLabel("Stop recitation")
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4)
        .background(Color.cvSurfaceContainer)
        .accessibilityIdentifier("reader.audio")
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

    let ayahs: [SurahReaderModel.Ayah]
    /// The basmala, from the edition's own 1:1. Empty for At-Tawba, and empty
    /// when the Arabic is not on the device.
    let basmala: String
    let restoreTo: Int32?
    let search: String
    let arabicTextScale: Double
    let language: QuranReadingMode
    let selectedAyah: Int32?
    let copiedAyah: Int32?
    let autoScroll: QuranReaderAutoScroll
    let isBookmarked: (Int32) -> Bool
    let onToggleBookmark: (Int32) -> Void
    let onTopAyahChanged: (Int32) -> Void
    let onSelect: (Int32) -> Void
    let onCopy: (SurahReaderModel.Ayah) -> Void
    let onListen: (SurahReaderModel.Ayah) -> Void

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows currently on screen, so the reader can tell where it is. The
    /// header is 0 and an ayah is its own number.
    ///
    /// Tracked from the rows' own appear/disappear rather than from
    /// `scrollPosition(id:)`, which only works inside a `ScrollView`. It is a
    /// `List` here deliberately — see `body`.
    @State private var visibleRows: Set<Int32> = []
    @State private var isRestoring = true

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
                SurahBasmala(basmala: language == .arabic ? basmala : "", arabicTextScale: arabicTextScale)
                    // Item 0 is the header — the top of the surah, which the shared
                    // reading-position rule already reads as "save nothing".
                    .id(Int32(0))
                    .listRowModifiers()
                    .onAppear { visibleRows.insert(0) }
                    .onDisappear { visibleRows.remove(0) }

                if isSearching {
                    Text(ayahs.isEmpty ? "No matching verses" : "\(ayahs.count) matching verses")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).listRowModifiers()
                }
                ForEach(ayahs) { ayah in
                    AyahVerse(
                        ayah: ayah,
                        arabicTextScale: arabicTextScale,
                        isBookmarked: isBookmarked(ayah.verse.ayahNumber),
                        onToggleBookmark: { onToggleBookmark(ayah.verse.ayahNumber) },
                        language: language, isSelected: selectedAyah == ayah.id,
                        isCopied: copiedAyah == ayah.id,
                        onSelect: { onSelect(ayah.id) },
                        onCopy: { onCopy(ayah) }, onListen: { onListen(ayah) }
                    )
                    .id(ayah.id)
                    .listRowModifiers(isVerse: true)
                    .onAppear { visibleRows.insert(ayah.id) }
                    .onDisappear { visibleRows.remove(ayah.id) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(Color.cvBackground)
            .accessibilityIdentifier("reader.verses")
            .overlay {
                QuranReaderScrollConnection(driver: autoScroll)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { autoScroll.pause() })
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { autoScroll.pause() }
            }
            .onChange(of: search) { _, _ in
                pendingClear?.cancel()
                isRestoring = true
            }
            .onChange(of: language) { _, _ in
                if let top = topRow {
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(top, anchor: .top)
                    }
                }
            }
            // Keyed by the target, so a position re-read on a later appearance
            // re-anchors the page instead of being ignored because this task had
            // already run once.
            .task(id: "\(restoreTo ?? 0):\(search)") {
                isRestoring = true
                pendingClear?.cancel()
                defer { isRestoring = false }
                let target = isSearching ? ayahs.first?.id : (restoreTo ?? 0)
                guard let target else { return }
                // One turn of the runloop later than the rows exist, and repeated
                // because the first request can still land before the list has laid
                // its rows out. A reader who has scrolled in the meantime simply
                // re-anchors where they asked to be.
                for attempt in 0..<5 {
                    if attempt > 0 {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                    guard !Task.isCancelled else { return }
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
                guard !isSearching, !isRestoring, let top = rows.filter({ $0 > 0 }).min() else { return }
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
                if !isSearching, !isRestoring, atTop, let top = visibleRows.filter({ $0 > 0 }).min() {
                    pendingClear?.cancel()
                    pendingClear = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, isAtScrollTop else { return }
                        onTopAyahChanged(top)
                    }
                }
            }
            .onDisappear { pendingClear?.cancel(); autoScroll.pause() }
        }
    }
}

private extension View {
    /// The list-row chrome a reader should not see: no separator, no inset, no
    /// background of its own, so a row of scripture looks exactly as it did in the
    /// scroll view this replaced.
    ///
    /// - Parameter isVerse: a verse row gets the mushaf page's own leading. The
    ///   space between verses is what separates one ayah from the next now that no
    ///   card does — Android's `spacedBy(26.dp)` — while the header above the first
    ///   verse keeps only a small gap so the surah's name still reads as the page's
    ///   heading rather than as another verse.
    func listRowModifiers(isVerse: Bool = false) -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .padding(.horizontal)
            .padding(.vertical, isVerse ? ReaderMetrics.verseGap : 6)
    }
}

/// The reader's own measurements, where no token exists for them.
private enum ReaderMetrics {
    /// Two neighboring rows keep 26 points between their reading text.
    static let verseGap: CGFloat = 13
}

/// The basmala that opens the surah — the one line above verse 1.
///
/// The surah's number, name, meaning and length are NOT here any more: they live in
/// the banner pinned above the text (`SurahBanner`), which is where Android keeps
/// them, so the page itself begins with the line the Quran itself begins with
/// rather than repeating a heading that is already on screen. That also means the
/// banner can be folded away without the identity disappearing — the same two
/// pieces Android split into `SurahBanner` and `SurahHead`.
///
/// The basmala rides in the header row rather than as a row of its own because it
/// is not an ayah. A row of its own would give it a row id, and the row ids here
/// are what the reading position is measured in (a surah is counted in ayahs) — a
/// synthetic id would have to be argued about in every one of those rules. As the
/// last thing above verse 1 it is also simply where it belongs on the page.
///
/// Rendered from the edition's own 1:1, never typed here, and centred and tinted
/// with the accent exactly as Android's `SurahHead` draws it. Like Android, it is
/// omitted only for At-Tawba — which is why Al-Faatiha shows it twice (it is that
/// surah's own first ayah as well); that is the Android behaviour, deliberately
/// kept rather than quietly special-cased here.
private struct SurahBasmala: View {
    let basmala: String
    let arabicTextScale: Double

    /// Android's `quranFontSize(24f)` for the basmala — smaller than a verse's 30,
    /// so the line reads as the page's opening rather than as scripture that lost
    /// its number. It follows the reader's text size like every other Arabic
    /// surface, so the whole page scales together.
    private static let basmalaBaseSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !basmala.isEmpty {
                QuranTypography.arabic(
                    basmala,
                    baseSize: Self.basmalaBaseSize,
                    scale: arabicTextScale
                )
                    .lineSpacing(QuranTypography.lineSpacing(
                        baseSize: Self.basmalaBaseSize,
                        scale: arabicTextScale
                    ))
                    .foregroundStyle(Color.cvPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    // RTL set explicitly, for the same reason the verses set it:
                    // the system's guess from the bidi ranges flips a leading
                    // mark the wrong way.
                    .environment(\.layoutDirection, .rightToLeft)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

/// A verse keeps its Arabic ornament or English reference, with two tap actions.
private struct AyahVerse: View {
    let ayah: SurahReaderModel.Ayah
    let arabicTextScale: Double
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void
    let language: QuranReadingMode
    let isSelected: Bool
    let isCopied: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onListen: () -> Void

    private var reference: String { "\(ayah.verse.surahNumber):\(ayah.id)" }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if language == .arabic && !ayah.arabic.isEmpty { scripture }
                else { translation }
            }
            .accessibilityIdentifier(reference)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityAction(named: Text("Show verse actions"), onSelect)
            .accessibilityHint("Show Copy and Listen actions")

            if isSelected {
                HStack(spacing: 12) {
                    Button(action: onCopy) { Label(isCopied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                        .accessibilityIdentifier("reader.copy.\(reference)")
                    Button(action: onListen) { Label("Listen", systemImage: "headphones") }
                        .accessibilityIdentifier("reader.listen.\(reference)")
                }
                .font(.subheadline.weight(.medium)).buttonStyle(.borderless)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.cvPrimary.opacity(0.1), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button(isBookmarked ? "Remove bookmark" : "Bookmark verse", systemImage: "bookmark") {
                onToggleBookmark()
            }
        }
    }

    private var scripture: some View {
        // Both halves go through `QuranTypography.arabic` rather than one shared
        // `.font` below the concatenation: the ornament is scripture too, and a
        // surface that set the face only on the verse would draw the ayah's own
        // number in the system font.
        (
            QuranTypography.arabic(
                ayah.arabic + "  ",
                baseSize: QuranTypography.readerBaseSize,
                scale: arabicTextScale
            )
                .foregroundStyle(Color.cvOnSurface)
            + QuranTypography.arabic(
                QuranTypography.ayahOrnament(ayah.id),
                baseSize: QuranTypography.readerBaseSize,
                scale: arabicTextScale
            )
                .foregroundStyle(isBookmarked ? Color.cvPrimary : Color.cvOnSurfaceVariant)
        )
        // The line box is set on the concatenation, not inside `arabic`:
        // `lineSpacing` is a `View` modifier, so this is the only place that can
        // space the verse and its ornament as one paragraph.
        .lineSpacing(QuranTypography.lineSpacing(
            baseSize: QuranTypography.readerBaseSize,
            scale: arabicTextScale
        ))
        .multilineTextAlignment(.center)
        .environment(\.layoutDirection, .rightToLeft)
        .frame(maxWidth: .infinity)
    }

    private var translation: some View {
        Text(ayah.verse.text + "  [\(ayah.id)]")
            .font(.system(size: 16 * arabicTextScale, weight: .medium, design: .serif))
            .lineSpacing(10 * arabicTextScale)
            .foregroundStyle(Color.cvOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
