import Foundation

/// A permanent live-stream SOURCE for Haramayn Live (Makkah / Madinah).
///
/// The OFFICIAL YouTube channel is the stable identity: the currently-airing
/// broadcast video id changes over time, but the channel id never does, so this
/// type stores ONLY channel identifiers. The current live video is discovered at
/// runtime from the channel (see ``LiveStreamResolver``) and is NEVER hardcoded
/// here — an app update is never needed because a new broadcast started.
///
/// Ported from the Android app's `LiveStreamSource`, so both apps point at the
/// same official channels.
struct LiveStreamSource: Identifiable, Equatable {
    /// Stable config key, e.g. `"makkah"` / `"madinah"`.
    let id: String
    /// Short UI label, e.g. `"Makkah Live"`.
    let title: String
    /// Longer UI caption, e.g. `"Masjid al-Haram · Live from Makkah"`.
    let subtitle: String
    /// Official channel name (Saudi Qur'an TV / Saudi Sunnah TV).
    let name: String
    /// Official YouTube channel id — the stable identity.
    let channelId: String
    /// Official channel page URL, the base for the resolver's discovery endpoints.
    let channelUrl: String

    /// The channel's `/live` page: resolves to the current broadcast, or to the
    /// channel page when nothing is airing.
    var liveUrl: URL? { URL(string: "https://www.youtube.com/channel/\(channelId)/live") }
}

/// Centralized configuration for Haramayn Live, mirroring Android's
/// `LiveStreamConfig`.
///
/// Both primary sources are the OFFICIAL YouTube channels of the Saudi
/// Broadcasting Authority — the only sources ever used:
///
///  - Makkah  → Saudi Qur'an TV (قناة القرآن الكريم) — live from Masjid al-Haram.
///  - Madinah → Saudi Sunnah TV (قناة السنة النبوية) — live from Al-Masjid an-Nabawi.
///
/// Makkah additionally has a BACKUP channel (AlQuran4k القرآن الكريم), used only
/// when the primary channel has no valid live broadcast — the same graceful
/// fallback Android performs. Madinah has no backup on either platform.
///
/// Only channel identity lives here. A new broadcast never requires an app
/// update; to switch or add sources later, only this file needs editing.
enum LiveStreamConfig {

    static let makkah = LiveStreamSource(
        id: "makkah",
        title: "Makkah Live",
        subtitle: "Masjid al-Haram · Live from Makkah",
        name: "Saudi Qur'an TV",
        channelId: "UCos52azQNBgW63_9uDJoPDA",
        channelUrl: "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA"
    )

    static let madinah = LiveStreamSource(
        id: "madinah",
        title: "Madinah Live",
        subtitle: "Al-Masjid an-Nabawi · Live from Madinah",
        name: "Saudi Sunnah TV",
        channelId: "UCROKYPep-UuODNwyipe6JMw",
        channelUrl: "https://www.youtube.com/channel/UCROKYPep-UuODNwyipe6JMw"
    )

    /// The selectable locations, in the order they are shown.
    static let streams: [LiveStreamSource] = [makkah, madinah]

    /// Fallback source used when a primary channel's broadcast is unavailable.
    static let backupStreams: [String: LiveStreamSource] = [
        "makkah": LiveStreamSource(
            id: "makkah_backup",
            title: "Makkah Live (Backup)",
            subtitle: "AlQuran4k القرآن الكريم · Backup",
            name: "AlQuran4k القرآن الكريم",
            channelId: "UCfBw_uwZb_oFLyVsjWk6owQ",
            channelUrl: "https://www.youtube.com/channel/UCfBw_uwZb_oFLyVsjWk6owQ"
        )
    ]

    static func stream(id: String) -> LiveStreamSource? {
        streams.first { $0.id == id } ?? backupStreams[id] ?? backupStreams.values.first { $0.id == id }
    }
}
