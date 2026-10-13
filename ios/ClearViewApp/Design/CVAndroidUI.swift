import SwiftUI

/// The Material 3 pieces the Android app is built from, rebuilt in SwiftUI.
///
/// The point of this file is that a screen ported from Compose should be able to
/// name the same component the Kotlin does — `CVTopBar`, `CVFilledTonalButton`,
/// `CVOutlinedButton`, `CVFont.titleLarge` — and get the same measurements. Where
/// a value below looks oddly specific (a 64-point bar, a 40-point button,
/// 24-point leading, a 0.1 tracking) it is Material's own number, taken from
/// `androidx.compose.material3`'s token set, which is what the Android app
/// renders.
///
/// ## Why not the native SwiftUI equivalents
///
/// `NavigationStack`'s bar and `.bordered`/`.borderedProminent` buttons are the
/// iOS conventions, and they are the wrong answer here: the brief is an app that
/// looks like the Android one, and the differences are not cosmetic (position of
/// the title, the 24-point horizontal padding, the pill shape, the tonal fill,
/// the uppercase-free labels). Rebuilding the six components the app actually
/// uses is less work than fighting each of the native ones into place, and it
/// keeps the two platforms diffable.
enum CVFont {

    /// Material's type scale, in points. `size`, `line`, `tracking` — the same
    /// three numbers `TextStyle` carries.
    static func scale(_ size: CGFloat, line: CGFloat, tracking: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // ── Display ───────────────────────────────────────────────────────────
    static var displaySmall: Font { .system(size: 36, weight: .regular) }

    // ── Headline ──────────────────────────────────────────────────────────
    static var headlineMedium: Font { .system(size: 28, weight: .regular) }
    /// `headlineSmall` — the surah name on the verse page (24/32).
    static var headlineSmall: Font { .system(size: 24, weight: .regular) }

    // ── Title ─────────────────────────────────────────────────────────────
    /// `titleLarge` — a top app bar's title (22/28).
    static var titleLarge: Font { .system(size: 22, weight: .regular) }
    /// `titleMedium` — the English translation on the verse page (16/24, medium).
    static var titleMedium: Font { .system(size: 16, weight: .medium) }
    /// `titleSmall` — the Previous/Next labels (14/20, medium).
    static var titleSmall: Font { .system(size: 14, weight: .medium) }

    // ── Body ──────────────────────────────────────────────────────────────
    static var bodyLarge: Font { .system(size: 16, weight: .regular) }
    static var bodyMedium: Font { .system(size: 14, weight: .regular) }
    static var bodySmall: Font { .system(size: 12, weight: .regular) }

    // ── Label ─────────────────────────────────────────────────────────────
    /// `labelLarge` — button and chip text (14/20, medium).
    static var labelLarge: Font { .system(size: 14, weight: .medium) }
    static var labelMedium: Font { .system(size: 12, weight: .medium) }
    static var labelSmall: Font { .system(size: 11, weight: .medium) }
}

/// A Material 3 small top app bar.
///
/// 64 points tall, filled with `surfaceContainer`, the title in `titleLarge` on
/// the left and up to three actions on the right. Android's own bar is
/// `TopAppBar`, and every screen in this app uses it, so a ported screen draws
/// this instead of a navigation bar.
struct CVTopBar<Leading: View, Trailing: View>: View {

    let title: String
    var subtitle: String? = nil
    /// `surfaceContainer` by default — what `TopAppBarDefaults` resolves to. The
    /// More tab overrides it with `surface`, and says so.
    var container: Color = .cvSurfaceContainer
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(CVFont.titleLarge)
                    .foregroundStyle(Color.cvOnSurface)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(CVFont.bodySmall)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .padding(.leading, titleLeadingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .frame(height: 64)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(container)
    }

    /// Material puts the title 16 points in when there is no navigation icon and
    /// 4 points after a 48-point icon button when there is one.
    private var titleLeadingPadding: CGFloat { 16 }
}

/// A Material 3 icon button: a 24-point glyph centred in a 48-point touch
/// target, at the bar's own 4-point inset — which is what makes a row of them
/// line up with the title.
struct CVIconButton: View {
    let systemName: String
    var label: String
    var tint: Color = .cvOnSurfaceVariant
    var enabled = true
    /// A stable name for tests, where the visible label is ambiguous: the bar's
    /// headphones toggle and the page's own Listen control are both "Listen",
    /// because that is what each is called, and only one of them exists at a time.
    var identifier: String? = nil
    /// The state a toggle is in, for readers who cannot see the icon change. A
    /// glyph that is filled or outlined says nothing out loud, so a switch has to
    /// say which way it is thrown.
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(enabled ? tint : Color.cvOnSurfaceVariant.opacity(0.38))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier ?? label)
    }
}

/// A Material 3 icon button with a badge — the bell, when there is something to
/// count. The badge is a `Badge` in Material's language: a small error-coloured
/// pill over the icon's top-right, capped at "99+".
struct CVBadgedIconButton: View {
    let systemName: String
    var label: String
    var count: Int
    var tint: Color = .cvOnSurfaceVariant
    var enabled = true
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(enabled ? tint : Color.cvOnSurfaceVariant.opacity(0.38))
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.cvOnError)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cvError, in: Capsule())
                        .offset(x: 8, y: -6)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
    }
}

/// The three Material 3 button fillings this app uses.
///
/// One type with a style rather than three views, because the difference really
/// is the fill: every other measurement (40-point height, pill shape, 24-point
/// horizontal padding, 18-point icon with an 8-point gap, `labelLarge` text) is
/// shared, and splitting it three ways is how they drift apart.
struct CVButton: View {

    enum Style {
        /// `FilledTonalButton` — the app's primary action on a page ("New Verse").
        case tonal
        /// `Button` — a solid accent fill.
        case filled
        /// `OutlinedButton` — the secondary action ("Copy verse", "Previous").
        case outlined
        /// `TextButton` — a bare action, for sheet actions.
        case text
    }

    let title: String
    var systemImage: String? = nil
    var style: Style = .tonal
    var enabled = true
    var expand = false
    var compact = false
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
                }
                Text(title).font(CVFont.labelLarge)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 16 : 24)
            .frame(height: compact ? 34 : 40)
            .frame(maxWidth: expand ? .infinity : nil)
            .background(background, in: Capsule())
            .overlay {
                if style == .outlined {
                    Capsule().stroke(outlineColor, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? title)
    }

    private var foreground: Color {
        switch style {
        case .tonal: return .cvOnSecondaryContainer
        case .filled: return .cvOnPrimary
        case .outlined, .text: return .cvPrimary
        }
    }

    private var background: Color {
        switch style {
        case .tonal: return .cvSecondaryContainer
        case .filled: return .cvPrimary
        case .outlined, .text: return .clear
        }
    }

    private var outlineColor: Color { .cvOutline }
}

/// A Material 3 horizontal divider: one hairline point of `outlineVariant`.
struct CVDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.cvOutlineVariant)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// A Material 3 `HorizontalDivider`-topped sheet body.
///
/// Bottom sheets in Material 3 open with a drag handle centred at the top and
/// their content 16 points below it; this is that container, so every ported
/// sheet opens the same way.
struct CVSheet<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.cvOutlineVariant)
                .frame(width: 32, height: 4)
                .padding(.top, 8)
                .padding(.bottom, title == nil ? 8 : 16)

            if let title {
                Text(title)
                    .font(CVFont.titleLarge)
                    .foregroundStyle(Color.cvOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            content
        }
        .frame(maxWidth: .infinity)
        .background(Color.cvSurfaceContainerHigh)
    }
}

/// A Material 3 list row: a 16/24 content inset, a title in `bodyLarge`, an
/// optional supporting line in `bodyMedium`/`onSurfaceVariant`, an optional
/// trailing control, and a 1-point divider when it is not the last row.
struct CVListRow<Trailing: View>: View {
    let title: String
    var supporting: String? = nil
    var systemImage: String? = nil
    var selected = false
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(selected ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CVFont.bodyLarge)
                        .foregroundStyle(selected ? Color.cvPrimary : Color.cvOnSurface)
                    if let supporting {
                        Text(supporting)
                            .font(CVFont.bodyMedium)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 56)

            if showsDivider {
                CVDivider().padding(.leading, systemImage == nil ? 16 : 56)
            }
        }
        .contentShape(Rectangle())
    }
}
