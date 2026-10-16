import SwiftUI
import UniformTypeIdentifiers

/// Advertisement management.
///
/// The Android app has had this since cards could be placed; iOS had the whole repository
/// surface — `adminAds`, `adminCreateAd`, `adminUpdateAd`, `adminDeleteAd` — and no screen that
/// called any of it, so the carousel a reader sees was whatever had been set up elsewhere. This
/// is the screen that manages it.
@MainActor
@Observable
final class AdsAdminModel {
    let repository: GoodPostRepository
    private(set) var ads: [GoodPostAd] = []
    var loading = false
    var message: String?
    /// The row whose toggle is in flight, so it cannot be flipped twice before the server answers.
    var pending: Set<String> = []

    init(repository: GoodPostRepository) {
        self.repository = repository
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await repository.adminAds()
        if let value = result.value {
            ads = value
            message = nil
        } else {
            message = result.userMessage
        }
    }

    /// Turns a card on or off.
    ///
    /// Sent as the whole card rather than as a flag, because the update route replaces what it is
    /// given — a partial body would clear the fields it left out.
    func setEnabled(_ ad: GoodPostAd, _ enabled: Bool) async {
        guard !pending.contains(ad.id) else { return }
        pending.insert(ad.id)
        defer { pending.remove(ad.id) }
        let result = await repository.adminUpdateAd(adId: ad.id, body: Self.body(for: ad, enabled: enabled))
        if result.value != nil {
            await load()
        } else {
            message = result.userMessage
        }
    }

    func delete(_ ad: GoodPostAd) async {
        let result = await repository.adminDeleteAd(adId: ad.id)
        if result.isOk { await load() } else { message = result.userMessage }
    }

    /// The card as the wire wants it, with only `enabled` changed.
    ///
    /// Spelled out in one place because the two callers — the toggle and the editor's save — must
    /// agree about every field, and a second inlined body is how a card silently loses its
    /// colours.
    static func body(for ad: GoodPostAd, enabled: Bool? = nil) -> [String: Any] {
        [
            "contentType": ad.contentType,
            "text": ad.text ?? NSNull(),
            "targetUrl": (ad.targetUrl ?? "").trimmed.isEmpty ? NSNull() : ad.targetUrl!,
            "showInChannels": ad.showInChannels,
            "showInExplore": ad.showInExplore,
            "enabled": enabled ?? ad.enabled,
            "priority": ad.priority,
            "startsAt": ad.startsAt ?? NSNull(),
            "expiresAt": ad.expiresAt ?? NSNull(),
            "textColor": ad.textColor,
            "backgroundColor": ad.backgroundColor,
            "imageFit": ad.imageFit,
            "imageFocusX": ad.imageFocusX,
            "imageFocusY": ad.imageFocusY,
        ]
    }
}

struct GoodPostAdsView: View {
    let repository: GoodPostRepository
    @State private var model: AdsAdminModel
    @State private var editing: GoodPostAd?
    @State private var creating = false
    @State private var deleting: GoodPostAd?

    init(repository: GoodPostRepository) {
        self.repository = repository
        _model = State(initialValue: AdsAdminModel(repository: repository))
    }

    var body: some View {
        List {
            if let message = model.message {
                CVErrorBanner(message: message) { Task { await model.load() } }
                    .listRowBackground(Color.clear)
            }
            Section("Advertisements") {
                ForEach(model.ads) { ad in
                    Button { editing = ad } label: { AdRow(ad: ad) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = ad }
                        }
                }
                if model.ads.isEmpty && !model.loading {
                    Text("No advertisement cards yet.")
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
                if model.loading { ProgressView() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.cvBackground)
        .navigationTitle("Advertisements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New card", systemImage: "plus") { creating = true }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $creating, onDismiss: { Task { await model.load() } }) {
            GoodPostAdEditView(ad: nil, repository: repository)
        }
        .sheet(item: $editing, onDismiss: { Task { await model.load() } }) { ad in
            GoodPostAdEditView(ad: ad, repository: repository)
        }
        .confirmationDialog(
            "Delete this advertisement?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete card", role: .destructive) {
                if let ad = deleting { Task { await model.delete(ad) } }
                deleting = nil
            }
        }
    }
}

/// One row: what the card is, where it appears, and whether it is running.
private struct AdRow: View {
    let ad: GoodPostAd

    /// Where the card appears, named the way the menu that lists them names it.
    private var placements: String {
        var where_: [String] = []
        if ad.showInExplore { where_.append("Explore") }
        if ad.showInChannels { where_.append("Channels") }
        return where_.isEmpty ? "Nowhere" : where_.joined(separator: " · ")
    }

    /// A card with no words is described by what it is, which is the only thing it has.
    private var title: String {
        let text = ad.displayText
        if !text.isEmpty { return text }
        return ad.isImage ? "Image card" : "Text card"
    }

    var body: some View {
        HStack(spacing: 12) {
            if ad.isImage, let raw = ad.imageUrl {
                RemoteImage(url: raw, placeholder: AnyView(Color.cvSurfaceContainer))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(Color.cvPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(placements).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            Spacer(minLength: 0)
            // Read-only here; the switch is the editor's. A row that toggled on a tap would make
            // opening a card and flipping it the same gesture.
            Text(ad.enabled ? "On" : "Off")
                .font(.caption.bold())
                .foregroundStyle(ad.enabled ? Color.cvPrimary : Color.cvOnSurfaceVariant)
        }
        .contentShape(Rectangle())
    }
}

/// Create or edit one card.
struct GoodPostAdEditView: View {
    /// nil to create.
    let ad: GoodPostAd?
    let repository: GoodPostRepository
    @Environment(\.dismiss) private var dismiss

    @State private var contentType: String
    @State private var text: String
    @State private var targetUrl: String
    @State private var showInChannels: Bool
    @State private var showInExplore: Bool
    @State private var enabled: Bool
    @State private var priority: String
    @State private var textColor: String
    @State private var backgroundColor: String
    @State private var imageFit: String
    @State private var mediaId: String?
    @State private var showFiles = false
    @State private var uploading = false
    @State private var busy = false
    @State private var message: String?

    init(ad: GoodPostAd?, repository: GoodPostRepository) {
        self.ad = ad
        self.repository = repository
        _contentType = State(initialValue: ad?.contentType ?? "text")
        _text = State(initialValue: ad?.text ?? "")
        _targetUrl = State(initialValue: ad?.targetUrl ?? "")
        _showInChannels = State(initialValue: ad?.showInChannels ?? false)
        _showInExplore = State(initialValue: ad?.showInExplore ?? true)
        _enabled = State(initialValue: ad?.enabled ?? true)
        _priority = State(initialValue: String(ad?.priority ?? 100))
        _textColor = State(initialValue: ad?.textColor ?? adDefaultTextColor)
        _backgroundColor = State(initialValue: ad?.backgroundColor ?? adDefaultBackgroundColor)
        _imageFit = State(initialValue: ad?.imageFit ?? "cover")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What the card is") {
                    Picker("Type", selection: $contentType) {
                        Text("Text").tag("text")
                        Text("Image").tag("image")
                    }.pickerStyle(.segmented)

                    if contentType == "text" {
                        TextField("What the card says", text: $text, axis: .vertical).lineLimit(2...6)
                    } else {
                        Button("Choose a picture", systemImage: "photo") { showFiles = true }
                            .disabled(busy || uploading)
                        if mediaId != nil || (ad?.imageUrl ?? "").isEmpty == false {
                            Text(mediaId != nil ? "New picture ready" : "Keeping the current picture")
                                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                        Picker("Fit", selection: $imageFit) {
                            Text("Cover").tag("cover")
                            Text("Contain").tag("contain")
                        }.pickerStyle(.segmented)
                        if uploading { ProgressView("Uploading…") }
                    }

                    TextField("Link (http, https or mailto)", text: $targetUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                Section("Where it appears") {
                    Toggle("Explore", isOn: $showInExplore)
                    Toggle("Channels", isOn: $showInChannels)
                    Toggle("Enabled", isOn: $enabled)
                    HStack {
                        Text("Priority")
                        Spacer()
                        TextField("100", text: $priority)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                    }
                }

                Section("Colours") {
                    ColourRow(title: "Background", selection: $backgroundColor, options: adBackgroundColors)
                    ColourRow(title: "Text", selection: $textColor, options: adTextColors)
                }

                if let message {
                    Section { Text(message).foregroundStyle(Color.cvError) }
                }
            }
            .navigationTitle(ad == nil ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: [.jpeg, .png, .gif],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await upload(url) }
                } else if case .failure = result {
                    message = "Couldn't open that picture."
                }
            }
        }
        .tint(.cvPrimary)
    }

    private func upload(_ url: URL) async {
        uploading = true
        defer { uploading = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            guard (values.fileSize ?? 0) <= 104_857_600 else {
                message = "Choose a picture smaller than 100 MB."
                return
            }
            guard let attachment = await readGoodPostAttachment(
                at: url,
                declaredContentType: values.contentType?.preferredMIMEType
            ) else {
                message = "That picture's format isn't supported."
                return
            }
            let result = await repository.adminUploadMedia(attachment: attachment)
            if let media = result.value {
                mediaId = media.id
                message = nil
            } else {
                message = result.userMessage
            }
        } catch {
            message = "Couldn't read that picture. Please select it again."
        }
    }

    private func save() async {
        let trimmed = text.trimmed
        // The same two refusals Android makes, and in the same place — before the round trip.
        if contentType == "text" && trimmed.isEmpty {
            message = "A text card needs something to say."
            return
        }
        if contentType == "image" && mediaId == nil && (ad?.imageUrl ?? "").isEmpty {
            message = "An image card needs a picture."
            return
        }
        // Checked against the schemes the server actually accepts, which is NOT what
        // `BrowserDestination` allows: that type is for opening a page and refuses `mailto`,
        // while a card is allowed to be an address — and using it here would have rejected a
        // valid `mailto:` card with a message saying `mailto:` was fine.
        let link = targetUrl.trimmed
        if !link.isEmpty {
            let allowed = ["http", "https", "mailto"]
            guard let scheme = URL(string: link)?.scheme?.lowercased(), allowed.contains(scheme) else {
                message = "Enter a valid http, https or mailto link."
                return
            }
        }
        busy = true
        defer { busy = false }

        var body: [String: Any] = [
            "contentType": contentType,
            "text": contentType == "text" ? trimmed : NSNull(),
            "targetUrl": link.isEmpty ? NSNull() : link,
            "showInChannels": showInChannels,
            "showInExplore": showInExplore,
            "enabled": enabled,
            "priority": Int(priority.trimmed) ?? 100,
            "startsAt": ad?.startsAt ?? NSNull(),
            "expiresAt": ad?.expiresAt ?? NSNull(),
            "textColor": textColor,
            "backgroundColor": backgroundColor,
            "imageFit": imageFit,
            "imageFocusX": ad?.imageFocusX ?? 0.5,
            "imageFocusY": ad?.imageFocusY ?? 0.5,
        ]
        // Sent only when a NEW picture is being claimed; omitted on an edit that keeps the
        // existing one, which the server reads as "leave it".
        if let mediaId { body["mediaId"] = mediaId }

        let result: ApiResult<GoodPostAd>
        if let ad {
            result = await repository.adminUpdateAd(adId: ad.id, body: body)
        } else {
            result = await repository.adminCreateAd(body: body)
        }
        if result.value != nil { dismiss() } else { message = result.userMessage }
    }
}

/// A row of swatches, because the card editor's job is to keep a card legible.
///
/// A fixed palette rather than a colour wheel: every one of these is legible on the card's
/// surfaces, which is the only property that matters and the one a free picker lets somebody get
/// wrong.
private struct ColourRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { hex in
                        Button { selection = hex } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colour(hex))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selection == hex ? Color.cvPrimary : Color.cvOutlineVariant,
                                                lineWidth: selection == hex ? 2.5 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(hex)")
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    private func colour(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return Color.cvSurfaceContainer }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}
