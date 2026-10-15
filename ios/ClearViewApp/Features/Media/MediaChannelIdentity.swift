import Foundation

/// Feed providers identify profiles by handle; subscriptions may use a directory
/// ID or a UUID. Keep the subscription's ID when storing its fetched items.
enum MediaChannelIdentity {
    static func platform(_ value: String) -> String {
        switch value.lowercased() {
        case "ig", "instagram": return "instagram"
        case "twitter", "x": return "x"
        case "yt", "youtube": return "youtube"
        default: return value.lowercased()
        }
    }

    static func handle(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(string: value).flatMap { $0.host == nil ? nil : $0.pathComponents.first(where: { $0 != "/" }) } ?? value
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
    }

    static func sameProfile(_ first: DirectoryChannel, _ second: DirectoryChannel) -> Bool {
        platform(first.platform) == platform(second.platform) && handle(first.handle) == handle(second.handle)
    }

    static func sourceID(for channel: DirectoryChannel) -> String? {
        switch platform(channel.platform) {
        case "instagram": return "ig_" + handle(channel.handle)
        case "x": return "x_" + handle(channel.handle)
        default: return nil
        }
    }

    static func repairing(_ video: LibraryVideo, channels: [DirectoryChannel]) -> LibraryVideo {
        guard let oldID = video.channelID,
              !channels.contains(where: { $0.id == oldID }),
              let owner = channels.first(where: { sourceID(for: $0)?.lowercased() == oldID.lowercased() }) else { return video }
        var repaired = video
        repaired.channelID = owner.id
        return repaired
    }
}
