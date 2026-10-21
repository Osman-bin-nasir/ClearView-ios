import SwiftUI

struct AppFilterSettingsView: View {
    let site: AppSite
    let library: AppsLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var inputError: String?
    @FocusState private var editing: Bool

    private var prefs: AppBrowsingPreferences { library.preferences(for: site) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AppBrandMark(site: site, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make \(site.name) yours").font(.headline)
                            Text("Changes apply as you browse.").font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                    }.padding(.vertical, 6)
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    Toggle(isOn: Binding(get: { library.blocksShortVideos(for: site) }, set: { value in
                        library.update(site) { $0.blockShortVideos = value }
                    })) {
                        Label("Hide \(site.shortVideoName)", systemImage: "eye.slash")
                    }.tint(.cvPrimary).disabled(library.protectionBlocksShortVideos(for: site))
                        .accessibilityIdentifier("apps.hide-short-videos")
                } header: { Text("SHORT VIDEOS") } footer: {
                    if library.protectionBlocksShortVideos(for: site) {
                        Text("Shorts are blocked in Protection. Change that setting in Shared protection rules before allowing them here.")
                    } else {
                        Text(prefs.blockShortVideos
                             ? "Removes the \(site.shortVideoName) button from navigation and hides short-video shelves. Regular videos and posts stay available."
                             : "\(site.shortVideoName) stay available. Videos and posts that match your keywords are hidden.")
                    }
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    HStack(spacing: 10) {
                        TextField("Word, phrase or creator", text: $keyword)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.done).focused($editing).onSubmit(addKeyword)
                            .accessibilityLabel("Blocked keyword")
                        Button(action: addKeyword) { Image(systemName: "plus.circle.fill").font(.title2) }
                            .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Add keyword")
                    }
                    if let inputError { Text(inputError).font(.caption).foregroundStyle(.red) }
                    if prefs.keywords.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What would you like to see less of?").font(.subheadline.weight(.medium))
                            Text("Add a topic, phrase or creator name. For example, add “prank” to hide posts that mention it.")
                                .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                        }.padding(.vertical, 6)
                    }
                    ForEach(prefs.keywords, id: \.self) { value in
                        HStack {
                            Image(systemName: "number").foregroundStyle(Color.cvPrimary)
                            Text(value).font(.subheadline)
                            Spacer()
                            Button(role: .destructive) {
                                library.update(site) { $0.keywords.removeAll { $0 == value } }
                            } label: { Image(systemName: "minus.circle").foregroundStyle(Color.cvOnSurfaceVariant) }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(value)")
                        }
                    }.onDelete { offsets in
                        library.update(site) { $0.keywords.remove(atOffsets: offsets) }
                    }
                } header: { Text("BLOCKED KEYWORDS · \(prefs.keywords.count)") } footer: {
                    Text("Matches the titles, captions, hashtags, image descriptions and creator names available on the page. Filtering checks text, not the video’s images or audio. Keywords apply throughout this app, including \(site.shortVideoName).")
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    NavigationLink {
                        ProtectionView(model: ProtectionModel.shared)
                    } label: {
                        Label("Shared protection rules", systemImage: "checkmark.shield")
                    }
                } footer: {
                    Text("Apps includes ClearView’s adult keyword filter. Your enabled Protection rules also apply; app settings cannot turn them off.")
                }.listRowBackground(Color.cvSurfaceContainerLow)

                Section {
                    Label("Sign in on the original website", systemImage: "lock")
                        .font(.subheadline)
                    Text("\(site.name) handles your account and stores its session on this device. ClearView does not collect your password. Some sign-in providers may require a supported browser; a Safari login does not transfer here.")
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                }.listRowBackground(Color.cvSurfaceContainerLow)
            }
            .scrollContentBackground(.hidden).background(Color.cvBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("\(site.name) filters").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }

    private func addKeyword() {
        guard let normalized = ProtectionStore.normalizeKeyword(keyword) else { return }
        guard normalized.count <= 100 else { inputError = "Keep each keyword under 100 characters."; return }
        guard prefs.keywords.count < 100 else { inputError = "You can add up to 100 keywords per app."; return }
        guard !prefs.keywords.contains(normalized) else { inputError = "That keyword is already in your list."; return }
        library.update(site) { $0.keywords.append(normalized) }
        keyword = ""
        inputError = nil
        editing = true
    }
}
