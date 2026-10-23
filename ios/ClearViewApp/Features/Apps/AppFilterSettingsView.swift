import SwiftUI

struct AppFilterSettingsView: View {
    @State private var site: AppSite
    let library: AppsLibrary
    @State private var keyword = ""
    @State private var inputError: String?
    @FocusState private var editing: Bool

    init(site: AppSite, library: AppsLibrary) {
        self._site = State(initialValue: site)
        self.library = library
    }

    private var prefs: AppBrowsingPreferences { library.preferences(for: site) }

    var body: some View {
        List {
                Section {
                    Picker("Apply keywords to", selection: $site) {
                        Text("All websites").tag(AppSite.web)
                        Text("YouTube").tag(AppSite.youtube)
                        Text("Instagram").tag(AppSite.instagram)
                        Text("Snapchat").tag(AppSite.snapchat)
                        Text("Facebook").tag(AppSite.facebook)
                    }
                } footer: { Text("All-website keywords apply to every shortcut and web search. App keywords add to those rules.") }
                    .listRowBackground(Color.cvSurfaceContainerLow)

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
                    Text("Matches the titles, captions, hashtags, image descriptions and creator names available on the page. Filtering checks text, not the video’s images or audio. Changes apply immediately to the selected scope.")
                }.listRowBackground(Color.cvSurfaceContainerLow)

            }
            .scrollContentBackground(.hidden).background(Color.cvBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Blocked words & creators").navigationBarTitleDisplayMode(.inline)
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
