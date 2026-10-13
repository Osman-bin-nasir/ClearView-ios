import SwiftUI
import PhotosUI
import UIKit

/// Edit a channel: its picture, name, description and category.
///
/// iOS has had `adminUpdateChannel` since the publisher studio was written and nothing that
/// called it, so a channel's picture was whatever it was created with and could never be
/// changed. This is the form that changes it.
///
/// Everything except the picture is a field. The picture gets its own card because it is the
/// one thing a person looks at rather than types into, and because it has three states, not
/// one: the picture that is there, one just picked, and none. Removing is a real choice rather
/// than an absence — which is why it is offered, and why it can be taken back before saving
/// rather than only by picking the old file again.
///
/// A picked photo is shown from this phone's own bytes the moment it is picked, not when the
/// upload answers: the bytes are already here, and a form that replaces the photograph somebody
/// chose with a letter while it works reads as though the choice was lost.
struct ChannelEditView: View {
    let channel: GoodPostChannel
    let isSuperAdmin: Bool
    let repository: GoodPostRepository
    /// The channel the server saved, handed back rather than re-read — the screen this form was
    /// opened from draws its own copy, and reloading a list does not touch it.
    let onSaved: (GoodPostChannel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var summary: String
    @State private var categorySlug: String?
    @State private var verified: Bool
    @State private var categories: [GoodPostCategory] = []
    @State private var picked: PhotosPickerItem?
    @State private var preview: UIImage?
    /// The uploaded picture's id, or nil while none is chosen or the upload has not landed.
    /// Absent from the request entirely when nil and nothing was removed — "leave it alone" is
    /// what renaming a channel has to mean, and sending a value would re-claim an upload.
    @State private var iconMediaId: String?
    @State private var iconRemoved = false
    @State private var uploading = false
    @State private var busy = false
    @State private var message: String?

    init(
        channel: GoodPostChannel,
        isSuperAdmin: Bool,
        repository: GoodPostRepository,
        onSaved: @escaping (GoodPostChannel) -> Void
    ) {
        self.channel = channel
        self.isSuperAdmin = isSuperAdmin
        self.repository = repository
        self.onSaved = onSaved
        _name = State(initialValue: channel.name)
        _summary = State(initialValue: channel.description ?? "")
        _categorySlug = State(initialValue: channel.categorySlug)
        _verified = State(initialValue: channel.verified)
    }

    /// Long enough to draw an avatar and no longer — an avatar renders in a 116-point circle, so
    /// sending a camera's full resolution spends the reader's data on pixels nobody sees.
    private func downscaled(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        iconPreview
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $picked, matching: .images) {
                                Text(hasPicture ? "Change photo" : "Add photo")
                            }
                            .disabled(busy || uploading)
                            if hasPicture && !iconRemoved {
                                Button("Remove", role: .destructive) {
                                    preview = nil
                                    picked = nil
                                    iconMediaId = nil
                                    iconRemoved = true
                                }
                                .disabled(busy)
                            }
                            if iconRemoved {
                                Button("Keep the old photo") {
                                    iconRemoved = false
                                }
                                .disabled(busy)
                            }
                        }
                        if uploading { ProgressView("Saving the photo…") }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                Section("Channel details") {
                    TextField("Channel name", text: $name)
                    TextField("Description", text: $summary, axis: .vertical).lineLimit(3...8)
                }

                if !categories.isEmpty {
                    Section("Category") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                CVChip(title: "None", selected: categorySlug == nil) { categorySlug = nil }
                                ForEach(categories) { category in
                                    CVChip(title: category.label, selected: categorySlug == category.slug) {
                                        categorySlug = category.slug
                                    }
                                }
                            }.padding(.vertical, 2)
                        }
                        // Only a super administrator may set this — the server drops the field
                        // from anyone else, and a switch that does nothing is worse than one
                        // that is not there.
                        if isSuperAdmin {
                            Toggle("Verified", isOn: $verified)
                        }
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(Color.cvError) }
                }
            }
            .navigationTitle("Edit channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || name.trimmed.isEmpty)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .tint(.cvPrimary)
        .task {
            if let loaded = await repository.categories().value { categories = loaded }
        }
        .onChange(of: picked) { _, item in Task { await pick(item) } }
    }

    private var hasPicture: Bool {
        preview != nil || (!iconRemoved && (channel.iconUrl ?? "").trimmed.isEmpty == false)
    }

    @ViewBuilder
    private var iconPreview: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else if !iconRemoved, let raw = channel.iconUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initial
                }
            } else {
                initial
            }
            if uploading {
                Circle().stroke(Color.cvPrimary, lineWidth: 3)
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.cvOutlineVariant.opacity(0.4)))
        .accessibilityLabel("Channel photo")
    }

    private var initial: some View {
        ZStack {
            Color.cvPrimaryContainer
            Text(String(name.trimmed.prefix(1)).uppercased())
                .font(.system(size: 40, weight: .bold)).foregroundStyle(Color.cvPrimary)
        }
    }

    /// Turns a picked photo into a pending upload.
    ///
    /// The bytes are re-encoded to JPEG rather than sent as picked: a photo library hands back
    /// whatever the camera wrote — HEIC on most iPhones — and normalising here means the upload
    /// has one known content type instead of a format the server has to be asked about. It also
    /// bakes the orientation in, so an avatar is not drawn sideways.
    private func pick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true
        // The selection is cleared once it has been handled, so choosing the SAME photo again
        // still reports itself — a picker that goes on holding the last selection never fires
        // again for it, which leaves a failed upload with no way to retry that file.
        defer {
            uploading = false
            picked = nil
        }
        // Dropped before the new one is attempted. Otherwise a second pick that fails would
        // leave the FIRST upload's id in place, and saving would quietly set a picture the
        // reader had already moved on from.
        iconMediaId = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            message = "Couldn't read that photo. Try another one."
            return
        }
        let normalised = downscaled(image)
        guard let jpeg = normalised.jpegData(compressionQuality: 0.9), !jpeg.isEmpty else {
            message = "Couldn't read that photo. Try another one."
            preview = nil
            return
        }
        preview = normalised
        iconRemoved = false

        // The upload reads from a file, so the normalised bytes go to one for the length of the
        // PUT. It is removed as soon as the answer arrives, either way.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-icon-\(UUID().uuidString).jpg")
        do { try jpeg.write(to: url) } catch {
            message = "Couldn't prepare that photo. Try another one."
            preview = nil
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let attachment = await readGoodPostAttachment(at: url, declaredContentType: "image/jpeg") else {
            message = "That photo isn't a format this app can upload."
            preview = nil
            return
        }
        let result = await repository.adminUploadMedia(attachment: attachment)
        if let media = result.value {
            iconMediaId = media.id
            message = nil
        } else {
            message = result.userMessage
            preview = nil
        }
    }

    private func save() async {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { message = "Give the channel a name."; return }
        // An upload still in flight blocks the save: the alternative is a channel saved with the
        // picture the reader chose silently missing.
        if preview != nil && iconMediaId == nil {
            message = uploading ? "Wait for the photo to finish saving." : "The photo didn't upload. Pick it again."
            return
        }
        var body: [String: Any] = ["name": trimmed]
        body["description"] = summary.trimmed.isEmpty ? NSNull() : summary.trimmed
        body["categorySlug"] = categorySlug ?? NSNull()
        if isSuperAdmin { body["verified"] = verified }
        // Sent only when the picture is actually changing. Absent means "leave it alone".
        if let iconMediaId { body["iconMediaId"] = iconMediaId }
        else if iconRemoved { body["iconMediaId"] = NSNull() }

        busy = true
        defer { busy = false }
        let result = await repository.adminUpdateChannel(channelId: channel.id, body: body)
        if let updated = result.value {
            onSaved(updated)
            dismiss()
        } else {
            message = result.userMessage
        }
    }
}
