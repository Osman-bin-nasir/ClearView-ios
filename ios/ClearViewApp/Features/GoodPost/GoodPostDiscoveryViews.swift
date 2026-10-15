import SwiftUI
import Observation

@MainActor
@Observable
final class GoodPostDiscoveryModel {
    var sections: [ChannelSection: [GoodPostChannel]] = [:]
    var errors: [ChannelSection: String] = [:]
    var ads: [GoodPostAd] = []
    var loading = false

    func load(repository: GoodPostRepository) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if let cached = await repository.cachedAds(placement: .explore) { ads = cached.ads }
        if let live = await repository.ads(placement: .explore).value { ads = live }
        for section in ChannelSection.allCases {
            guard !Task.isCancelled else { return }
            let result = await repository.channels(category: section.category, sort: section.sort, limit: 3)
            if let page = result.value {
                sections[section] = page.items
                errors[section] = nil
            } else { errors[section] = result.userMessage }
        }
    }
}

struct GoodPostChannelName: View {
    let channel: GoodPostChannel
    var lineLimit = 1

    var body: some View {
        HStack(spacing: 5) {
            Text(channel.name).font(.system(size: 17, weight: .bold)).lineLimit(lineLimit)
            if channel.verified {
                Image(systemName: "checkmark.seal.fill").font(.subheadline)
                    .foregroundStyle(Color.cvPrimary).accessibilityLabel("Verified channel")
            }
        }
    }
}

struct GoodPostNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.cvOnSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GoodPostPalette.accent).frame(minWidth: 48, minHeight: 44)
        }.padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
            .background(GoodPostPalette.bar)
    }
}

struct GoodPostDiscoverRow: View {
    let channel: GoodPostChannel
    @Bindable var model: GoodPostScreenModel

    private var following: Bool { model.followedIDs.contains(channel.id) }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { ChannelFeedView(channel: channel, model: model) } label: {
                HStack(spacing: 12) {
                    CVAvatar(name: channel.name, url: channel.iconUrl, size: 49)
                    VStack(alignment: .leading, spacing: 7) {
                        GoodPostChannelName(channel: channel, lineLimit: 2)
                        Text(channel.followerCount > 0
                            ? "\(channel.followerCount) \(channel.followerCount == 1 ? "follower" : "followers")"
                            : channel.categoryLabel ?? "Channel")
                            .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { Task { await model.toggleFollow(channel) } } label: {
                Text(following ? "Following" : "Follow").font(.subheadline.bold())
                    .foregroundStyle(following ? Color.primary : Color.cvOnPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 10).fixedSize(horizontal: true, vertical: false)
                    .background(following ? Color.clear : Color.cvPrimary, in: Capsule())
                    .overlay(Capsule().stroke(following ? Color.cvOnSurfaceVariant.opacity(0.4) : Color.clear))
            }.buttonStyle(.plain).disabled(model.pendingFollows.contains(channel.id))
                .opacity(model.pendingFollows.contains(channel.id) ? 0.5 : 1)
                .accessibilityLabel("\(following ? "Unfollow" : "Follow") \(channel.name)")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct GoodPostAdCarousel: View {
    let ads: [GoodPostAd]
    @State private var selectedID: String?
    @Environment(\.openURL) private var openURL

    private var activeAds: [GoodPostAd] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return ads.filter { $0.enabled && $0.isActive(at: now) }
    }

    var body: some View {
        if !activeAds.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $selectedID) {
                    ForEach(activeAds) { ad in
                        Button {
                            if let target = ad.targetUrl, let url = URL(string: target),
                               let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
                                openURL(url)
                            }
                        } label: { card(ad) }
                            .buttonStyle(.plain)
                            .disabled(ad.targetUrl == nil)
                            .tag(Optional(ad.id))
                            .padding(.horizontal, 16)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 185)
                if activeAds.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(activeAds) { ad in
                            Circle().fill((selectedID ?? activeAds.first?.id) == ad.id
                                ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                    }.accessibilityLabel("Advertisement \(pageNumber) of \(activeAds.count)")
                }
            }.onChange(of: activeAds.map(\.id), initial: true) { _, identifiers in
                if selectedID == nil || !identifiers.contains(selectedID ?? "") { selectedID = identifiers.first }
            }
        }
    }

    private var pageNumber: Int {
        (activeAds.firstIndex { $0.id == selectedID } ?? 0) + 1
    }

    private func card(_ ad: GoodPostAd) -> some View {
        GeometryReader { geometry in
            ZStack {
                adColor(ad.backgroundColor, fallback: .cvSurfaceContainer)
                if ad.isImage, let source = ad.imageUrl, let url = URL(string: source) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: ad.imageFit == "contain" ? .fit : .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } placeholder: {
                        Image(systemName: "photo").foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                } else {
                    Text(ad.displayText).font(.title3.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(adColor(ad.textColor, fallback: .primary)).padding(24)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private func adColor(_ hex: String, fallback: Color) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return fallback }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct GoodPostChannelDirectoryView: View {
    @Bindable var model: GoodPostScreenModel
    let section: ChannelSection?
    @State private var search = ""
    @State private var sort: ChannelSortChip
    @State private var channels: [GoodPostChannel] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var message: String?
    @State private var requestID = UUID()

    init(model: GoodPostScreenModel, section: ChannelSection? = nil) {
        self.model = model
        self.section = section
        _sort = State(initialValue: ChannelSortChip.fromSort(section?.sort ?? "popular"))
    }

    private var queryKey: String { search + "|" + sort.rawValue }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CVSearchField(text: $search, prompt: "Search channels").padding(16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChannelSortChip.allCases, id: \.self) { option in
                            CVChip(title: option.title, selected: option == sort) { sort = option }
                        }
                    }.padding(.horizontal, 16)
                }.padding(.bottom, 12)
                if let message { GoodPostNotice(message: message) { Task { await load() } } }
                if let message = model.message {
                    GoodPostNotice(message: message) { Task { await model.load() } }
                }
                ForEach(channels) { channel in GoodPostDiscoverRow(channel: channel, model: model) }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(24) }
                if !loading && message == nil && channels.isEmpty {
                    CVEmptyState(title: "Nothing here yet", message: "Try another search or sorting option.", symbol: "person.2")
                        .padding(24)
                }
                if nextCursor != nil {
                    Button("Load more channels") { Task { await load(more: true) } }
                        .frame(maxWidth: .infinity).padding(20).disabled(loading)
                }
            }.padding(.bottom, 24)
        }.background(Color.cvBackground)
            .navigationTitle(section.map { $0 == .explore ? "Trending channels" : $0.title } ?? "Search channels")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onChange(of: queryKey) { _, _ in
                requestID = UUID()
                nextCursor = nil
                channels = []
                message = nil
            }
            .task(id: queryKey) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await load()
            }
            .refreshable { await load() }
    }

    private func load(more: Bool = false) async {
        if more && (loading || nextCursor == nil) { return }
        let identifier = UUID()
        requestID = identifier
        loading = true
        message = nil
        if !more { channels = []; nextCursor = nil }
        defer { if requestID == identifier { loading = false } }
        let result = await model.repository.channels(query: search.trimmed.isEmpty ? nil : search.trimmed,
            category: section?.category, sort: sort.sort, cursor: more ? nextCursor : nil)
        guard !Task.isCancelled, requestID == identifier else { return }
        if let page = result.value {
            let existing = Set(channels.map(\.id))
            channels = more ? channels + page.items.filter { !existing.contains($0.id) } : page.items
            nextCursor = page.nextCursor
        } else { message = result.userMessage }
    }
}

struct GoodPostSavedChannelsView: View {
    @Bindable var model: GoodPostScreenModel
    @State private var search = ""

    private var channels: [GoodPostChannel] {
        model.channels.filter {
            model.savedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CVSearchField(text: $search, prompt: "Search saved channels").padding(16)
                Text("Saved on this iPhone").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                ForEach(channels) { channel in
                    NavigationLink { ChannelFeedView(channel: channel, model: model) } label: {
                        ChannelRow(channel: channel)
                    }.buttonStyle(.plain)
                }
                if channels.isEmpty {
                    CVEmptyState(title: "Keep good voices close", message: "Save a channel to find it here.", symbol: "bookmark")
                        .padding(24)
                }
            }
        }.background(Color.cvBackground).navigationTitle("Saved channels")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
