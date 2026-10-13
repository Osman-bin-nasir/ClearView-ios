import SwiftUI

/// The ClearView palette, as native SwiftUI colours.
///
/// These values are ported from the Android theme
/// (`app/src/main/java/com/muddassir/clearview/ui/theme/Theme.kt`) so a screen
/// that exists on both platforms is recognisably the same app. The accent family
/// is the app's designed deep **teal** — deliberately not the template purple
/// that still sits unused in `Color.kt`.
///
/// ## Why adaptive colours instead of a `Palette` struct
///
/// Android picks a scheme itself (a designed light scheme, and on Android 12+ a
/// wallpaper-derived dark one from Material You). iOS has no wallpaper-colour
/// API, and the platform convention is to follow the system appearance. So each
/// token here is resolved by the system from `userInterfaceStyle`: the app looks
/// native, and light/dark/Appearance switching is free.
///
/// Both schemes are the app's own designed ones — neither is left to the
/// framework, for the reason the Android theme's own comment gives: an
/// undefined surface role falls back to a baseline purple that fights a teal
/// accent.
extension Color {

    // ── Accent ────────────────────────────────────────────────────────────
    static let cvPrimary = Color.cvAdaptive(dark: 0x63DACB, light: 0x00695C)
    static let cvOnPrimary = Color.cvAdaptive(dark: 0x003731, light: 0xFFFFFF)
    static let cvPrimaryContainer = Color.cvAdaptive(dark: 0x005046, light: 0xA7F0E4)
    static let cvOnPrimaryContainer = Color.cvAdaptive(dark: 0xA7F0E4, light: 0x00201C)

    // ── Page ──────────────────────────────────────────────────────────────
    static let cvBackground = Color.cvAdaptive(dark: 0x0F1514, light: 0xEDF1EF)
    static let cvOnBackground = Color.cvAdaptive(dark: 0xDDE4E3, light: 0x171D1C)
    static let cvSurface = Color.cvAdaptive(dark: 0x0F1514, light: 0xFAFCFB)
    static let cvOnSurface = Color.cvAdaptive(dark: 0xDDE4E3, light: 0x171D1C)

    // ── Cards ─────────────────────────────────────────────────────────────
    // The three container levels the feed and sheets are built from, so a card
    // reads as a card without a heavy border. Kept as separate tokens because
    // the Android side uses them separately.
    static let cvSurfaceContainerLow = Color.cvAdaptive(dark: 0x131A19, light: 0xF4F8F6)
    static let cvSurfaceContainer = Color.cvAdaptive(dark: 0x171F1E, light: 0xEEF3F1)
    static let cvSurfaceContainerHigh = Color.cvAdaptive(dark: 0x1D2625, light: 0xE7EEEC)

    // ── Text and lines ────────────────────────────────────────────────────
    static let cvOnSurfaceVariant = Color.cvAdaptive(dark: 0xBEC9C7, light: 0x3F4947)
    static let cvOutline = Color.cvAdaptive(dark: 0x899390, light: 0x6B7472)
    static let cvOutlineVariant = Color.cvAdaptive(dark: 0x3F4947, light: 0xC6D1CE)

    // ── Status ────────────────────────────────────────────────────────────
    static let cvError = Color.cvAdaptive(dark: 0xFFB4AB, light: 0xB3261E)

    /// One token, two literals — resolved by the system from the appearance.
    fileprivate static func cvAdaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(cvRGB: dark) : UIColor(cvRGB: light)
        })
    }
}

private extension UIColor {
    /// `0xRRGGBB`, the same literal form the Kotlin palette uses, so the two
    /// files can be diffed line by line when a colour changes.
    convenience init(cvRGB rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
