import Foundation

/// The sleep timer as arithmetic, rather than as UI or as a field on the player.
///
/// A direct port of Android's `SleepTimer` object, because both the countdown
/// shown on the pill and the volume being lowered by the player have to agree: a
/// second of disagreement between them is a second of audio at the wrong level,
/// and the fade is the kind of thing that is wrong in a way nobody notices until
/// they are lying in the dark listening to something that will not stop.
///
/// Kept free of AVFoundation so the awkward half is unit-testable.
enum SleepTimer {

    /// The choices offered, in minutes.
    ///
    /// Five through an hour in the steps people actually want: the short end is
    /// "one more video", the long end is a whole talk or a night's reading. They
    /// are choices rather than a free field because a sleep timer is set in the
    /// dark, by feel, and a number pad there is a worse tool than four taps.
    static let minutes = [5, 10, 15, 30, 45, 60]

    /// How long the volume takes to reach silence at the end.
    ///
    /// Long enough to be a fade rather than a cut — audio stopping dead is a
    /// small shock in a quiet room, which is the opposite of the point — and
    /// short enough that nobody is awake waiting for it.
    static let fadeSeconds: Double = 3

    /// "12:30", or "1:02:30" past an hour.
    ///
    /// ROUNDED UP to the whole second, which matters more than it looks: a timer
    /// set to five minutes holds 299,999 ms a millisecond after it is set, and
    /// truncating would show "4:59" the instant the reader chose "5 minutes" — a
    /// control that appears to have ignored them. Rounding up means the first
    /// thing drawn is the time they asked for, and the last second still reads
    /// "0:01" rather than "0:00".
    static func formatRemaining(_ seconds: Double) -> String {
        // Integer ceiling division, written as `(n-1)/d + 1` rather than
        // `(n+999)/1000`: the additive form overflows to a NEGATIVE total for an
        // absurdly large remaining value, and a countdown that suddenly reads
        // "-1:-51" is worse than one that is merely wrong.
        let milliseconds = Int64((seconds * 1000).rounded())
        let totalSeconds = milliseconds <= 0 ? 0 : (milliseconds - 1) / 1000 + 1
        let hours = totalSeconds / 3600
        let minutesPart = (totalSeconds % 3600) / 60
        let secondsPart = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutesPart, secondsPart)
            : String(format: "%d:%02d", minutesPart, secondsPart)
    }

    /// The volume multiplier for `remaining` seconds left on the timer: 1 until
    /// the last ``fadeSeconds``, falling linearly to 0 at the deadline.
    ///
    /// A deadline the ticker overshoots yields a negative remainder on the way
    /// out (the player checks the same number for expiry a moment later), and
    /// that has to read as silence rather than as a negative volume.
    static func fadeVolume(remaining: Double) -> Float {
        if remaining <= 0 { return 0 }
        if remaining >= fadeSeconds { return 1 }
        return Float(remaining / fadeSeconds)
    }

    /// The pill's label: the countdown, or "Off".
    ///
    /// A remainder of 0 means no timer is set — the same thing the player
    /// reports, so there is one definition of "off" rather than two.
    static func label(forRemaining remaining: Double) -> String {
        remaining > 0 ? formatRemaining(remaining) : "Off"
    }
}
