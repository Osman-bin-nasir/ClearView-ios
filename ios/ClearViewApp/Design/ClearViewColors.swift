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

    // ── Secondary (the tonal fill) ────────────────────────────────────────
    // The second accent family: what a tonal button, a chip and a selected row
    // are painted with when the action is not the page's primary one.
    static let cvSecondary = Color.cvAdaptive(dark: 0xB1CCC7, light: 0x4A635F)
    static let cvOnSecondary = Color.cvAdaptive(dark: 0x1C3531, light: 0xFFFFFF)
    static let cvSecondaryContainer = Color.cvAdaptive(dark: 0x334B48, light: 0xCCE8E3)
    static let cvOnSecondaryContainer = Color.cvAdaptive(dark: 0xCCE8E3, light: 0x06201D)

    // ── Tertiary ──────────────────────────────────────────────────────────
    static let cvTertiary = Color.cvAdaptive(dark: 0xABCAE6, light: 0x43617A)
    static let cvOnTertiary = Color.cvAdaptive(dark: 0x11334B, light: 0xFFFFFF)
    static let cvTertiaryContainer = Color.cvAdaptive(dark: 0x2A4A62, light: 0xC9E6FF)
    static let cvOnTertiaryContainer = Color.cvAdaptive(dark: 0xC9E6FF, light: 0x001E31)

    // ── Cards ─────────────────────────────────────────────────────────────
    // The container levels the feed and sheets are built from, so a card reads
    // as a card without a heavy border. Kept as separate tokens because the
    // Android side uses them separately.
    static let cvSurfaceContainerLowest = Color.cvAdaptive(dark: 0x0B100F, light: 0xFFFFFF)
    static let cvSurfaceContainerLow = Color.cvAdaptive(dark: 0x131A19, light: 0xF4F8F6)
    static let cvSurfaceContainer = Color.cvAdaptive(dark: 0x171F1E, light: 0xEEF3F1)
    static let cvSurfaceContainerHigh = Color.cvAdaptive(dark: 0x1D2625, light: 0xE7EEEC)
    static let cvSurfaceContainerHighest = Color.cvAdaptive(dark: 0x232D2C, light: 0xE0E9E6)
    static let cvSurfaceVariant = Color.cvAdaptive(dark: 0x3F4947, light: 0xD8E3DF)
    static let cvSurfaceBright = Color.cvAdaptive(dark: 0x353F3E, light: 0xFCFEFD)
    static let cvSurfaceDim = Color.cvAdaptive(dark: 0x0F1514, light: 0xDBE2DF)
    /// The tint a Material surface is raised with where the platform draws one.
    static let cvSurfaceTint = Color.cvAdaptive(dark: 0x63DACB, light: 0x00695C)
    static let cvInverseSurface = Color.cvAdaptive(dark: 0xDDE4E3, light: 0x2C3231)
    static let cvInverseOnSurface = Color.cvAdaptive(dark: 0x2C3231, light: 0xDDE4E3)
    static let cvScrim = Color.black

    // ── Text and lines ────────────────────────────────────────────────────
    static let cvOnSurfaceVariant = Color.cvAdaptive(dark: 0xBEC9C7, light: 0x3F4947)
    static let cvOutline = Color.cvAdaptive(dark: 0x899390, light: 0x6B7472)
    static let cvOutlineVariant = Color.cvAdaptive(dark: 0x3F4947, light: 0xC6D1CE)

    // ── Status ────────────────────────────────────────────────────────────
    static let cvError = Color.cvAdaptive(dark: 0xFFB4AB, light: 0xB3261E)
    static let cvOnError = Color.cvAdaptive(dark: 0x690005, light: 0xFFFFFF)
    static let cvErrorContainer = Color.cvAdaptive(dark: 0x93000A, light: 0xFFDAD6)
    static let cvOnErrorContainer = Color.cvAdaptive(dark: 0xFFDAD6, light: 0x410002)

    /// One token, two literals — resolved by the system from the appearance.
    fileprivate static func cvAdaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(cvRGB: dark) : UIColor(cvRGB: light)
        })
    }
}

extension UIColor {

    /// The bottom bar's container: the theme's own `surface` at 62% opacity, on
    /// top of a transparent bar.
    ///
    /// Android builds its navigation bar this way — `surface.copy(alpha = 0.62f)`
    /// on a `NavigationBar` — so the page colour reads *through* the bar instead
    /// of the bar sitting on the page as a slab. UIKit wants a `UIColor`, which
    /// is why these three live here rather than being taken from the SwiftUI
    /// tokens: `UIColor(Color)` resolves against the trait collection of the
    /// moment it is called, not the view's, which is the wrong answer for a bar
    /// that must re-resolve on every appearance change.
    static let cvBarContainer = UIColor.cvDynamic(dark: 0x0F1514, light: 0xFAFCFB, alpha: 0.62)

    /// The selected item's tint: the accent, in both schemes.
    static let cvBarSelected = UIColor.cvDynamic(dark: 0x63DACB, light: 0x00695C)

    /// The unselected item's tint: `onSurfaceVariant`.
    static let cvBarUnselected = UIColor.cvDynamic(dark: 0xBEC9C7, light: 0x3F4947)

    /// One token, two literals, resolved by the system from the appearance — the
    /// UIColor twin of `Color.cvAdaptive`.
    fileprivate static func cvDynamic(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            let base = traits.userInterfaceStyle == .dark ? UIColor(cvRGB: dark) : UIColor(cvRGB: light)
            return base.withAlphaComponent(alpha)
        }
    }

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
