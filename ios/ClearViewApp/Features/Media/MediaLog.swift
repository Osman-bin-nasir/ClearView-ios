import os

/// Loggers for the Media tab's network-dependent work.
///
/// These exist because every failure in this feature is invisible otherwise: a
/// feed that answers `429`, a stream YouTube refuses, a download that dies
/// mid-transfer all surface in the UI as the same thing — nothing appears. The
/// subsystems are separated so a log stream can be filtered to one of them:
///
///     log stream --predicate 'subsystem == "com.muddassir.clearview"' --level debug
///
/// Messages are logged with `.public` only for values that are already visible on
/// screen (a video id the reader tapped, an HTTP status). Anything that could
/// carry a credential — a resolved stream URL, a signed CDN link — is logged as
/// `.private` so it is redacted rather than written to the device log in clear.
enum MediaLog {
    private static let subsystem = "com.muddassir.clearview"

    /// Extraction and background playback.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Offline audio transfers and the downloads manifest.
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    /// Instagram / X / YouTube feed refresh.
    static let feeds = Logger(subsystem: subsystem, category: "feeds")
}
