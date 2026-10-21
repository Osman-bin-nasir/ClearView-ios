import SwiftUI
import PhotosUI
import UIKit

/// Create or edit a channel — one form, two modes (§19, §20).
///
/// iOS has had `adminUpdateChannel` since the publisher studio was written and nothing that called
/// it, so a channel's picture was whatever it was created with and could never be changed. This is
/// the form that changes it, and the same form is how a new one is made: the fields are the same
/// fields, and the two differences are real ones rather than a flag — a new channel has no picture
/// to keep, and it mints the account that will run it.
///
/// # Two different things that were one field
///
///  * **minting an admin** — a NEW account is created beside the channel. Only a super administrator
///    may do it, and the email field belongs to it.
///  * **setting a password** — the EXISTING account's password is on offer, which is the edit form.
///    It is here so a forgotten channel password is a field rather than a support request, and so a
///    reset does not require the channel to be deleted and recreated. Blank means "leave it alone".
///
/// # A picked photo is shown from this phone's own bytes
///
/// The moment it is picked, not when the upload answers: the bytes are already here, and a form that
/// replaces the photograph somebody chose with a letter while it works reads as though the choice
/// was lost.
struct ChannelFormView: View {
    /// The channel being edited, or nil when one is being created.
    let channel: GoodPostChannel?
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
    /// Absent from the request entirely when nil and nothing was removed — "leave it alone" is what
    /// renaming a channel has to mean, and sending a value would re-claim an upload.
    @State private var iconMediaId: String?
    @State private var iconRemoved = false
    @State private var uploading = false
    @State private var busy = false
    @State private var message: String?
    @State private var adminEmail = ""
    @State private var adminPassword = ""

    /// The floor for a minted password (§10).
    ///
    /// The same number the server enforces (`adminMinPasswordLength` in the Android build), stated
    /// here as well so the answer comes back **with the rule in it** — a label that names the floor
    /// is what stops somebody trying four passwords in a row that were each one character short.
    private let passwordFloor = 8

    private var creating: Bool { channel == nil }

    init(
        channel: GoodPostChannel?,
        isSuperAdmin: Bool,
        repository: GoodPostRepository,
        onSaved: @escaping (GoodPostChannel) -> Void
    ) {
        self.channel = channel
        self.isSuperAdmin = isSuperAdmin
        self.repository = repository
        self.onSaved = onSaved
        _name = State(initialValue: channel?.name ?? "")
        _summary = State(initialValue: channel?.description ?? "")
        _categorySlug = State(initialValue: channel?.categorySlug)
        _verified = State(initialValue: channel?.verified ?? false)
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
                                Text(hasPicture ? "Change image" : "Add image")
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
                                Button("Keep") { iconRemoved = false }
                                    .disabled(busy)
                            }
                        }
                        if uploading { ProgressView("Saving the image…") }
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
                        // The platform's badge. Only a super administrator sees it, because only they
                        // can set it — the server drops the field from anyone else, and a switch that
                        // does nothing is worse than one that is not there.
                        if isSuperAdmin {
                            Toggle("Verified channel", isOn: $verified)
                        }
                    }
                }

                // Only a super administrator creates the account with the channel. A channel
                // administrator editing their own channel has no business minting credentials, and
                // the server refuses it anyway.
                if isSuperAdmin {
                    Section(creating
                        ? "The account that will run this channel"
                        : "Password for the account that runs this channel") {
                        if !creating {
                            Text("Leave this blank to keep the current password.")
                                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                        if creating {
                            TextField("Admin email", text: $adminEmail)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        SecureField(
                            creating
                                ? "Admin password (\(passwordFloor) characters or more)"
                                : "New password (\(passwordFloor) characters or more, optional)",
                            text: $adminPassword
                        )
                        // Declared as a NEW password so the Autofill service stops volunteering the
                        // operator's own login: this is a credential for somebody else, read off the
                        // screen to hand over.
                        .textContentType(creating ? .newPassword : .password)
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(Color.cvError) }
                }
            }
            .navigationTitle(creating ? "New channel" : "Edit channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Create a channel" : "Save") { Task { await save() } }
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
        preview != nil || (!iconRemoved && (channel?.iconUrl ?? "").trimmed.isEmpty == false)
    }

    @ViewBuilder
    private var iconPreview: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else if !iconRemoved, let raw = channel?.iconUrl {
                RemoteImage(url: raw, placeholder: AnyView(initial))
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
        .accessibilityLabel("Channel image")
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
    /// whatever the camera wrote — HEIC on most iPhones — and normalising here means the upload has
    /// one known content type instead of a format the server has to be asked about. It also bakes
    /// the orientation in, so an avatar is not drawn sideways.
    private func pick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true
        // The selection is cleared once it has been handled, so choosing the SAME photo again still
        // reports itself — a picker that goes on holding the last selection never fires again for
        // it, which leaves a failed upload with no way to retry that file.
        defer {
            uploading = false
            picked = nil
        }
        // Dropped before the new one is attempted. Otherwise a second pick that fails would leave
        // the FIRST upload's id in place, and saving would quietly set a picture the reader had
        // already moved on from.
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

        // The upload reads from a file, so the normalised bytes go to one for the length of the PUT.
        // It is removed as soon as the answer arrives, either way.
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

        // The password being minted for the channel's administrator, checked HERE rather than only
        // by the server. Not a second authority — the server still refuses a short one — but this
        // one can be produced without a round trip, and it is the answer that names the rule.
        if isSuperAdmin, !adminPassword.isEmpty, adminPassword.count < passwordFloor {
            message = "That password is too short. Use at least \(passwordFloor) characters."
            return
        }
        if creating, isSuperAdmin, adminEmail.trimmed.isEmpty {
            message = "Give the account that will run this channel an email address."
            return
        }

        // An upload still in flight blocks the save: the alternative is a channel saved with the
        // picture the reader chose silently missing.
        if preview != nil && iconMediaId == nil {
            message = uploading ? "Wait for the image to finish saving." : "The image didn't upload. Pick it again."
            return
        }

        var body: [String: Any] = ["name": trimmed]
        body["description"] = summary.trimmed.isEmpty ? NSNull() : summary.trimmed
        body["categorySlug"] = categorySlug ?? NSNull()
        if isSuperAdmin { body["verified"] = verified }
        if !adminEmail.trimmed.isEmpty { body["adminEmail"] = adminEmail.trimmed.lowercased() }
        if !adminPassword.isEmpty { body["adminPassword"] = adminPassword }
        // Sent only when the picture is actually changing. Absent means "leave it alone".
        if let iconMediaId { body["iconMediaId"] = iconMediaId }
        else if iconRemoved { body["iconMediaId"] = NSNull() }

        busy = true
        defer { busy = false }
        let result = creating
            ? await repository.adminCreateChannel(body: body)
            : await repository.adminUpdateChannel(channelId: channel?.id ?? "", body: body)
        if let updated = result.value {
            adminPassword = ""
            onSaved(updated)
            dismiss()
        } else {
            message = result.userMessage
        }
    }
}
