import SwiftUI

struct AddMediaChannelView: View {
    let library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var platform: FeedPlatformFilter?
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a platform, then enter its @handle or profile URL.").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                HStack(spacing: 8) {
                    ForEach([FeedPlatformFilter.youTube, .instagram, .x], id: \.self) { option in
                        CVChip(title: option.label, selected: platform == option) { platform = option; error = nil }
                    }
                }
                if let platform {
                    TextField("\(platform.label) handle or URL", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("media.channel.input")
                    if platform != .youTube {
                        Text("The profile is saved to your channels. \(platform.label) feed loading is not yet connected on iOS.").font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.cvError) }
                    CVButton(title: "Add", style: .filled) { add(platform) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }.padding(20).background(Color.cvBackground).navigationTitle("Add channel / profile").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func add(_ platform: FeedPlatformFilter) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: String
        if value.contains("://") { url = value }
        else {
            let handle = value.hasPrefix("@") ? String(value.dropFirst()) : value
            guard !handle.isEmpty, handle.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !handle.contains("/"), !handle.contains("?"), !handle.contains("#") else {
                error = "Enter a handle or a complete profile URL."; return
            }
            switch platform {
            case .youTube: url = "https://www.youtube.com/@\(handle)"
            case .instagram: url = "https://www.instagram.com/\(handle)"
            case .x: url = "https://x.com/\(handle)"
            case .all: return
            }
        }
        let host = URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        let validHost = platform == .youTube ? host == "youtube.com" : platform == .instagram ? host == "instagram.com" : host == "x.com" || host == "twitter.com"
        guard validHost, library.addChannel(url: url) else { error = "Enter a valid \(platform.label) profile link."; return }
        dismiss()
        Task { await library.refresh() }
    }
}

struct MediaFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FeedFilter
    @State private var expanded: String?
    @State private var start: Date
    @State private var end: Date
    let onApply: (FeedFilter) -> Void

    init(filter: FeedFilter, onApply: @escaping (FeedFilter) -> Void) {
        _draft = State(initialValue: filter)
        _start = State(initialValue: filter.customStartEpochMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date())
        _end = State(initialValue: filter.customEndEpochMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date())
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(FeedFilters.summary(draft, includeDefaultDate: true) + (draft.watchStatus == .unwatched ? " · Unwatched" : ""))
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                    choices("Date", selection: $draft.date, options: FeedDateFilter.allCases, label: { $0.label })
                    if draft.date == .custom {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                    }
                    choices("Platform", selection: $draft.platform, options: FeedPlatformFilter.allCases, label: { $0.label })
                    choices("Content", selection: $draft.content, options: FeedFilters.contentOptions(for: draft.platform), label: { $0.label })
                    choices("Source", selection: $draft.source, options: FeedSourceFilter.allCases, label: { $0.label })
                    choices("Watch status", selection: $draft.watchStatus, options: FeedWatchStatus.allCases, label: { $0.label })
                    choices("Sort by", selection: $draft.sort, options: FeedSortOrder.allCases, label: { $0.label })
                    Text("Watch status uses recorded playback progress, not whether a link was opened.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }.padding(20)
            }.background(Color.cvBackground).navigationTitle("Filter").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("Reset") { draft = FeedFilter(); expanded = nil } }
                }
                .safeAreaInset(edge: .bottom) {
                    CVButton(title: "Apply", style: .filled) {
                        if draft.date == .custom {
                            draft.customStartEpochMillis = Int64(Calendar.current.startOfDay(for: start).timeIntervalSince1970 * 1000)
                            let finalDay = Calendar.current.startOfDay(for: max(start, end))
                            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: finalDay) ?? finalDay
                            draft.customEndEpochMillis = Int64(nextDay.timeIntervalSince1970 * 1000) - 1
                        }
                        onApply(draft); dismiss()
                    }.padding(20).frame(maxWidth: .infinity).background(Color.cvBackground)
                }
                .onChange(of: draft.platform) { _, _ in draft = FeedFilters.normalizedForPlatform(draft) }
                .onChange(of: start) { _, value in if end < value { end = value } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func choices<Choice: Hashable>(_ title: String, selection: Binding<Choice>, options: [Choice], label: @escaping (Choice) -> String) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded == title }, set: { expanded = $0 ? title : nil })) {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button { selection.wrappedValue = option } label: {
                        HStack {
                            Text(label(option)).font(.subheadline).foregroundStyle(Color.cvOnSurface)
                            Spacer()
                            Image(systemName: selection.wrappedValue == option ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.cvPrimary)
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Text(title).font(.subheadline.bold()).foregroundStyle(Color.cvOnSurface)
                Spacer()
                Text(label(selection.wrappedValue)).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }.padding(.vertical, 8)
        }.padding(12).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct HaramaynView: View {
    @State private var madinah = false
    @State private var browser: BrowserDestination?

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                CVChip(title: "🕋 Makkah Live", selected: !madinah) { madinah = false }
                CVChip(title: "🕌 Madinah Live", selected: madinah) { madinah = true }
            }
            VStack(spacing: 16) {
                Text(madinah ? "🕌" : "🕋").font(.system(size: 60))
                Text(madinah ? "Saudi Sunnah TV" : "Saudi Quran TV").font(.title3.bold())
                Text("Open the official channel's current live broadcast.").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).multilineTextAlignment(.center)
                CVButton(title: "Watch live", style: .filled) {
                    let channel = madinah ? "UCROKYPep-UuODNwyipe6JMw" : "UCos52azQNBgW63_9uDJoPDA"
                    browser = BrowserDestination("https://www.youtube.com/channel/\(channel)/live")
                }
            }.frame(maxWidth: .infinity).padding(24).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 18))
            Text("Live playback currently opens in the in-app browser.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            Spacer()
        }.padding(20).background(Color.cvBackground).navigationTitle("Haramayn").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $browser) { BrowserSheet(url: $0.url) }
    }
}
