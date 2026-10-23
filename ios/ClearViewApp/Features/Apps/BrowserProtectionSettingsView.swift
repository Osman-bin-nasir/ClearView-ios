import SwiftUI

struct BrowserProtectionSettingsView: View {
    let library: AppsLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 25)).foregroundStyle(Color.cvPrimary)
                            .frame(width: 48, height: 48).background(Color.cvPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Browse with a little more intention.").font(.headline)
                            Text("What ClearView hides inside this browser").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section("Filtering") {
                    setting("Strict Mode", detail: "Also blocks discovery words like bikini and lingerie.", symbol: "shield.lefthalf.filled",
                            value: Binding(get: { ProtectionModel.shared.strictMode }, set: { ProtectionModel.shared.strictMode = $0 }), id: "browser.strict-mode")
                    NavigationLink {
                        AppFilterSettingsView(site: .web, library: library)
                    } label: {
                        Label("Blocked words & creators", systemImage: "text.badge.minus")
                    }
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section("Feeds & search") {
                    setting("Hide YouTube Shorts", detail: "Blocks Shorts entry points, shelves and direct links.", symbol: "play.rectangle",
                            value: shortBinding(.youtube), id: "browser.hide-shorts")
                        .disabled(library.protectionBlocksShortVideos(for: .youtube))
                    if library.protectionBlocksShortVideos(for: .youtube) {
                        Text("Shorts is also blocked in full ClearView protection.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    setting("Hide Instagram Reels", detail: "Removes Reels entry points and keeps Reels links from opening.", symbol: "film",
                            value: shortBinding(.instagram), id: "browser.hide-reels")
                    setting("Hide Snapchat Spotlight", detail: "Removes Spotlight entry points and keeps Spotlight links from opening.", symbol: "sparkles",
                            value: shortBinding(.snapchat), id: "browser.hide-spotlight")
                    setting("Hide Facebook Reels", detail: "Removes Reels entry points and keeps Reels links from opening.", symbol: "play.square.stack",
                            value: shortBinding(.facebook), id: "browser.hide-facebook-reels")
                    setting("Hide Google search categories", detail: "Keeps only the All tab; Images, Videos, News and the rest are hidden.", symbol: "line.3.horizontal.decrease",
                            value: browserBinding(\.hideGoogleCategories), id: "browser.hide-google-categories")
                    setting("Remove blocked videos from feed", detail: "Blocked cards leave the feed instead of only being covered.", symbol: "rectangle.stack.badge.minus",
                            value: browserBinding(\.removeBlockedCards), id: "browser.remove-blocked-cards")
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    setting("Block YouTube ads", detail: "Refuses ad requests, removes ad slots and skips video ads.", symbol: "hand.raised",
                            value: browserBinding(\.blockYouTubeAds), id: "browser.block-youtube-ads")
                } header: { Text("YouTube") } footer: {
                    Text("YouTube can change how ads are delivered; some ads may still get through.")
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    NavigationLink {
                        ProtectionView(model: ProtectionModel.shared)
                    } label: {
                        HStack {
                            Label("Open full ClearView protection…", systemImage: "checkmark.shield")
                            Spacer(minLength: 0)
                        }.foregroundStyle(Color.cvPrimary)
                    }
                } header: {
                    Text("Changes apply to this browser immediately. Some hidden feed items return when you turn a switch off. Tap page whitespace to show or hide the navigation bar.")
                        .font(.footnote).textCase(nil).padding(.bottom, 14)
                }.listRowBackground(Color.cvSurfaceContainerLow)
            }.scrollContentBackground(.hidden).background(Color.cvBackground)
                .navigationTitle("Protection settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(.cvPrimary).presentationDragIndicator(.visible)
    }

    private func shortBinding(_ site: AppSite) -> Binding<Bool> {
        Binding(get: { library.blocksShortVideos(for: site) }, set: { value in library.update(site) { $0.blockShortVideos = value } })
    }
    private func browserBinding(_ path: WritableKeyPath<BrowserProtectionPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { library.browserPreferences[keyPath: path] }, set: { value in library.updateBrowser { $0[keyPath: path] = value } })
    }
    private func setting(_ title: String, detail: String, symbol: String, value: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: value) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.cvPrimary).frame(width: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.cvOnSurface)
                    Text(detail).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 7)
        }.tint(.cvPrimary).accessibilityIdentifier(id)
    }
}
