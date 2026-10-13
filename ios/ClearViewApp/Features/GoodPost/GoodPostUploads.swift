import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Attaching a file to a post.
///
/// The composer's half of the media lifecycle. Three steps, in this order and no other:
///
///   1. **Ask the server for a place to put it** — the server answers with a presigned URL and a
///      media id, and it chooses the object key. No client ever names a path in the bucket.
///   2. **PUT the bytes** straight to the bucket, streamed from the picked file.
///   3. **Confirm**, which makes the server HEAD the object before it may be attached. "The
///      client says it uploaded" is not evidence, which is why a post can never carry an asset
///      that was never really there.
///
/// Two rules this file keeps:
///
///  * **A whole video is never held in memory.** The PUT is made from a file URL, so a 100 MB
///    clip costs a buffer rather than 100 MB of resident memory.
///  * **The allow-list is mirrored, not invented.** `goodPostAcceptedTypes` is the same set the
///    server accepts, so a file it would refuse is refused here with a sentence instead of a
///    round trip. The server is still the authority; this only makes the common refusal instant.

/// How far an attachment has got.
enum GoodPostUploadState: Equatable {
    /// Presigned, PUT in flight, or awaiting confirmation.
    case uploading
    /// Confirmed by the server and claimable.
    ///
    /// The media id is what the publish call attaches, so "the composer's ready files" and "the
    /// ids sent" are the same list by construction.
    case ready(mediaId: String)
    /// Refused, with the server's own code — or `unsupported_type` for a file this app will not
    /// even send.
    case failed(code: String)
}

/// One file the composer is holding.
///
/// On iOS a picked file is a URL — either a copy the picker made in the app's own container, or
/// a security-scoped location — so that URL is what is kept. The bytes are never copied: the PUT
/// reads them straight from there.
struct GoodPostAttachment: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    /// `image`, `video` or `document`.
    let kind: String
    let contentType: String
    let byteSize: Int64
    /// Hints for layout only; the server stores them and nothing depends on them.
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    /// What the file was called where it was picked.
    ///
    /// Sent with the upload and stored by the server for a **document**, because that name is
    /// the only thing its card has to show — a PDF draws no preview. For an image or a clip it
    /// is kept for the preview's own sake and is not sent.
    let fileName: String?
    var state: GoodPostUploadState

    init(
        id: String = UUID().uuidString,
        fileURL: URL,
        kind: String,
        contentType: String,
        byteSize: Int64,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int64? = nil,
        fileName: String? = nil,
        state: GoodPostUploadState = .uploading
    ) {
        self.id = id
        self.fileURL = fileURL
        self.kind = kind
        self.contentType = contentType
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fileName = fileName
        self.state = state
    }

    var isImage: Bool { kind == "image" }
    var isVideo: Bool { kind == "video" }
    var isDocument: Bool { kind == "document" }

    /// Ready to be attached to a post.
    var mediaId: String? {
        if case .ready(let mediaId) = state { return mediaId }
        return nil
    }

    /// The server's refusal, when there was one.
    var failureCode: String? {
        if case .failed(let code) = state { return code }
        return nil
    }

    /// What the chip shows: a document's own name, and something honest for the others.
    var displayName: String {
        if let fileName, !fileName.trimmed.isEmpty { return fileName }
        return kind == "video" ? "Video" : "Image"
    }

    /// The size a person reads — "1.4 MB", not "1468006 bytes".
    var displaySize: String {
        let units = ["KB", "MB", "GB"]
        var value = Double(byteSize) / 1024
        var index = 0
        while value >= 1024, index + 1 < units.count {
            value /= 1024
            index += 1
        }
        let rounded = value >= 10 || index == 0 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return "\(rounded) \(units[index])"
    }
}

/// The content types the backend will store.
///
/// An allow-list rather than a deny-list, mirrored from the server's own, and it exists for the
/// same reason there: what is stored under a URL anyone can fetch is what a browser will later
/// run. `image/svg+xml` is absent deliberately — an SVG served from our bucket domain is a
/// stored-XSS primitive. `application/pdf` is the one document type, matching the server's list
/// exactly, because a file this app would send and the server would refuse is a round trip that
/// ends in a refusal the composer could have worded before it started.
let goodPostAcceptedTypes: Set<String> = [
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/gif",
    "video/mp4",
    "video/quicktime",
    "video/webm",
    "application/pdf",
]

/// Which kind a content type belongs to, or nil when it is not accepted.
///
/// Pure, so it is tested directly — this decides what the composer lets a user pick, and a bug
/// here is a file that fails only after it has been uploaded.
func goodPostKind(for contentType: String?) -> String? {
    guard let contentType else { return nil }
    let base = contentType.split(separator: ";").first.map(String.init)?
        .trimmed
        .lowercased() ?? ""
    guard !base.isEmpty, goodPostAcceptedTypes.contains(base) else { return nil }
    if base.hasPrefix("image/") { return "image" }
    if base.hasPrefix("video/") { return "video" }
    // Named rather than "anything else in the set": the set is a list of *types*, and a type
    // added to it for some later purpose must not silently become a kind the server derives a
    // post's shape from.
    if base == "application/pdf" { return "document" }
    return nil
}

/// A picked file's content type, read from the bytes rather than from its name.
///
/// The declared type is checked first by the caller, and it is the declaration that is often
/// wrong: Files, Drive and several document providers answer about as often as they do, and a
/// PDF refused on that alone comes back as "that file type cannot be posted" — the app being
/// wrong about something it can simply look at. The signatures here are the same eight types
/// the allow-list holds, and an unrecognised header returns nil so the caller refuses rather
/// than guessing.
func sniffGoodPostContentType(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 16), header.count >= 4 else { return nil }

    let bytes = [UInt8](header)

    func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
        guard bytes.count >= offset + signature.count else { return false }
        return Array(bytes[offset..<(offset + signature.count)]) == signature
    }

    if matches([0x25, 0x50, 0x44, 0x46]) { return "application/pdf" } // %PDF
    if matches([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if matches([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if matches([0x47, 0x49, 0x46, 0x38]) { return "image/gif" } // GIF8
    if matches(Array("RIFF".utf8)), matches(Array("WEBP".utf8), at: 8) { return "image/webp" }
    // ISO base media files (MP4, QuickTime) carry their brand four bytes past `ftyp`.
    if matches(Array("ftyp".utf8), at: 4) {
        let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.trimmed ?? ""
        if brand == "qt" { return "video/quicktime" }
        return "video/mp4"
    }
    // Matroska/WebM's EBML header, with the "webm" doctype anywhere in the opening bytes.
    if matches([0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }
    return nil
}

/// Reads a picked file's metadata, or nil when it cannot be posted.
///
/// Nil means "do not offer this file": an unreadable type, a size that cannot be read, or a
/// location the picker has already revoked. Every failure is the same answer to the user — the
/// file was not attached — because a partially attached file is worse than an honest refusal.
///
/// The dimensions and duration are **best effort**. They are layout hints; the server stores
/// them but nothing depends on them, so a file whose header cannot be measured is attached
/// anyway rather than refused over a nice-to-have.
///
/// - Parameter declaredContentType: what the picker said the file is, when it said anything.
func readGoodPostAttachment(
    at fileURL: URL,
    declaredContentType: String? = nil
) async -> GoodPostAttachment? {
    let fileName = fileURL.lastPathComponent
    let declared = declaredContentType.flatMap { goodPostKind(for: $0) != nil ? $0 : nil }
    let sniffed = sniffGoodPostContentType(at: fileURL)

    // The declaration wins when it is one this app accepts; otherwise the bytes decide.
    guard let contentType = declared ?? sniffed,
          let kind = goodPostKind(for: contentType) else {
        return nil
    }

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
          let size = (attributes[.size] as? NSNumber)?.int64Value else {
        return nil
    }
    // A zero-length file would be signed, uploaded and confirmed as nothing; refusing it here
    // saves the round trip and the confusing empty post.
    guard size > 0 else { return nil }

    // A document's name is the whole of its card, so one with no name is refused here with the
    // same sentence as any other file this app will not send — rather than uploaded and then
    // refused by the server, which would spend the transfer to learn what is already known.
    let hasName = !fileName.trimmed.isEmpty && fileName != "."
    if kind == "document" && !hasName { return nil }

    let measured = await measure(fileURL, kind: kind)

    return GoodPostAttachment(
        fileURL: fileURL,
        kind: kind,
        contentType: contentType,
        byteSize: size,
        width: measured.width,
        height: measured.height,
        durationMs: measured.durationMs,
        fileName: hasName ? fileName : nil
    )
}

/// A file's pixel size and playback length, when the platform can read them.
private func measure(_ url: URL, kind: String) async -> (width: Int?, height: Int?, durationMs: Int64?) {
    switch kind {
    case "image":
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (width, height, nil)

    case "video":
        let asset = AVURLAsset(url: url)
        var durationMs: Int64?
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            durationMs = seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : nil
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else {
            return (nil, nil, durationMs)
        }
        return (Int(abs(size.width)), Int(abs(size.height)), durationMs)

    default:
        return (nil, nil, nil)
    }
}

/// The filename extension a content type should be uploaded under, when the local name lacks
/// one — a picker that hands over a temporary file with no extension otherwise uploads a PDF
/// whose name the server cannot show.
func goodPostFileName(for contentType: String, fallback: String) -> String {
    let base = fallback.trimmed.isEmpty ? "attachment" : fallback
    guard !base.contains(".") else { return base }
    let type = UTType(mimeType: contentType)
    guard let suffix = type?.preferredFilenameExtension else { return base }
    return "\(base).\(suffix)"
}
