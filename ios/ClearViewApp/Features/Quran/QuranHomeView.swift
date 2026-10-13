import SwiftUI
import AVFoundation
import SharedKotlin

@MainActor
@Observable
final class VerseAudioPlayer {
    var playing = false
    var error: String?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var completion: NSObjectProtocol?

    func toggle(surah: Int32, ayah: Int32) {
        if playing { stop(); return }
        error = nil
        let path = String(format: "%03d%03d", surah, ayah)
        guard let url = URL(string: "https://everyayah.com/data/Alafasy_128kbps/\(path).mp3") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = "Audio couldn't start. Please try again."; return }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                if failed { self?.stop(); self?.error = "Couldn't load recitation. Check your connection and try again." }
            }
        }
        completion = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        playing = true
        player?.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playing = false
        observation = nil
        if let completion { NotificationCenter.default.removeObserver(completion) }
        completion = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct QuranView: View {
    @State private var model = QuranModel()
    @State private var audio = VerseAudioPlayer()
    @State private var copied = false
    @State private var showLibrary = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if let verse = model.currentVerse, let surah = model.currentVerseSurah {
                        verseContent(verse, surah: surah)
                    } else if case .failed(let message) = model.state {
                        CVEmptyState(title: "A moment to reconnect", message: message, symbol: "wifi.exclamationmark")
                        Button("Try again") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
                    } else {
                        ProgressView("Preparing your Quran…").padding(.vertical, 100)
                    }
                    Divider().overlay(Color.cvOutlineVariant)
                    VStack(spacing: 5) {
                        Text(IslamicDate.format(date: Date(), adjustmentDays: IslamicDateStore().adjustmentDays)).font(.footnote.weight(.medium))
                        Text(Date().formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Button { showLibrary = true } label: {
                        HStack {
                            Image(systemName: "books.vertical").font(.title2).foregroundStyle(Color.cvPrimary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Browse Quran").font(.headline)
                                Text("114 surahs · Arabic & English").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(Color.cvPrimary)
                        }.padding(18).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityIdentifier("quran.browse")
                }.padding(24)
            }.background(Color.cvBackground).navigationTitle("Quran Reminder").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showLibrary = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Browse Quran")
                        NavigationLink { BookmarksView(repository: model.repository) } label: { Image(systemName: "bookmark") }.accessibilityLabel("Bookmarks")
                        Button { showSettings = true } label: { Image(systemName: "bell") }.accessibilityLabel("Reminder settings")
                    }
                }
                .task { await model.load() }
                .onDisappear { audio.stop() }
                .navigationDestination(isPresented: $showLibrary) { QuranLibraryView() }
                .sheet(isPresented: $showSettings) { NavigationStack { AppSettingsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                } } }
        }
    }

    private func verseContent(_ verse: QuranVerse, surah: SurahSummary) -> some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text("PAUSE. READ. REFLECT.").font(.system(size: 10, weight: .bold)).tracking(2.8).foregroundStyle(Color.cvPrimary)
                NavigationLink {
                    SurahReaderView(surah: surah, repository: model.repository, openAt: verse.ayahNumber)
                } label: {
                    VStack(spacing: 7) {
                        Text(surah.name).font(.title.bold())
                        Text(surah.translation).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                        Text("\(verse.surahNumber):\(verse.ayahNumber)").font(.caption.monospacedDigit())
                            .foregroundStyle(Color.cvPrimary).accessibilityIdentifier("quran.reminder.position")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityIdentifier("quran.reminder")
                ProgressView(value: Double(verse.ayahNumber), total: Double(max(1, surah.ayahCount)))
                    .tint(.cvPrimary).frame(width: 120)
            }.padding(.top, 16)
            if !verse.arabicText.isEmpty {
                Text(verse.arabicText).font(.system(size: 34, weight: .regular))
                    .lineSpacing(18).multilineTextAlignment(.center).environment(\.layoutDirection, .rightToLeft)
                    .frame(maxWidth: .infinity).padding(.vertical, 16).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                Button { audio.stop(); Task { await model.stepVerse(-1) } } label: { Label("Previous", systemImage: "arrow.left") }
                    .disabled(!model.canGoBackward).accessibilityIdentifier("quran.reminder.previous")
                Button { audio.stop(); Task { await model.stepVerse(1) } } label: { Label("Next", systemImage: "arrow.right") }
                    .disabled(!model.canGoForward).accessibilityIdentifier("quran.reminder.next")
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).font(.caption.weight(.medium))
            Text(verse.text).font(.system(size: 17, weight: .medium)).lineSpacing(7)
                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 620)
            if let error = model.verseError { CVErrorBanner(message: error) }
            Button { audio.toggle(surah: verse.surahNumber, ayah: verse.ayahNumber) } label: {
                Label(audio.playing ? "Stop recitation" : "Listen · Mishary Alafasy", systemImage: audio.playing ? "stop.circle" : "headphones")
                    .font(.footnote.weight(.medium))
            }
            if let error = audio.error { CVErrorBanner(message: error) }
            HStack(spacing: 12) {
                Button { audio.stop(); Task { await model.refreshVerse() } } label: { Label("New verse", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).accessibilityLabel("Show another verse")
                Button {
                    UIPasteboard.general.string = "\(verse.arabicText)\n\n\(verse.text)\n\nQuran \(verse.surahNumber):\(verse.ayahNumber)"
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy verse", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.bordered)
            }.buttonBorderShape(.capsule).font(.subheadline)
        }.onChange(of: verse.ayahNumber) { _, _ in copied = false }
    }
}
