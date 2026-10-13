import SwiftUI
import SharedKotlin

/// Every notification the app has, behind the one bell — `NotificationsSheet` in
/// `ui/ContentHubSheets.kt`.
///
/// Android's sheet is one list built from three legs: channel updates (news, and
/// the only thing that counts towards the badge), To Do reminders (which count
/// until they are read), and the Quran cadence (which never counts, because a
/// standing arrangement is not something that happened). The media and To Do legs
/// arrive with their own tabs; the Quran leg is here, drawn in the same shape so
/// the sheet does not have to be restructured when the others land.
struct NotificationsSheet: View {

    let model: QuranModel
    var onOpenVerse: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.cvOutlineVariant)
                .frame(width: 32, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 16)

            HStack {
                Text("Notifications")
                    .font(CVFont.titleLarge)
                    .foregroundStyle(Color.cvOnSurface)
                Spacer()
                Button("Done") { dismiss() }
                    .font(CVFont.labelLarge)
                    .foregroundStyle(Color.cvPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeading("Quran reminders")

                    if let verse = model.currentVerse {
                        NotificationRow(
                            title: "\(verse.surahName) \(verse.surahNumber):\(verse.ayahNumber)",
                            // The heading above already says "Quran reminders", so
                            // the row itself says the cadence rather than repeating
                            // which verse it is about.
                            detail: cadence,
                            unread: false,
                            onOpen: {
                                // Tapping it closes the sheet — the verse is the
                                // Quran tab, which the sheet is covering.
                                onOpenVerse?()
                                dismiss()
                            }
                        )
                    } else {
                        Text("Nothing yet.")
                            .font(CVFont.bodyMedium)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.cvSurfaceContainerHigh)
    }

    /// "Refreshes automatically every N hours · works offline" — Android's
    /// `quran_verse_refresh_note_hours` plural.
    private var cadence: String {
        let hours = model.refreshIntervalHours
        let unit = hours == 1 ? "hour" : "hours"
        return "Refreshes automatically every \(hours) \(unit) · works offline"
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(CVFont.labelLarge)
            .foregroundStyle(Color.cvPrimary)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// One entry in the sheet: the words, and — when the entry came from something
/// that happened — the accent dot that says it has not been read.
struct NotificationRow: View {
    let title: String
    /// The supporting line. Named `detail` rather than `body` because a `View`
    /// already has a `body`, and a stored property of that name is a redeclaration.
    let detail: String
    let unread: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(unread ? Color.cvPrimary : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CVFont.bodyLarge)
                        .foregroundStyle(Color.cvOnSurface)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(CVFont.bodyMedium)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The ±1 day Islamic-date adjustment — `IslamicDateAdjustmentSheet` in
/// `ui/ContentHubSheets.kt`.
///
/// The moon is not sighted on a calculator, so exactly three choices are offered:
/// yesterday's date, the calculated date, and tomorrow's. Anything wider would be
/// a different feature.
struct IslamicDateAdjustmentSheet: View {

    let adjustment: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private var options: [(days: Int, label: String)] {
        [
            (-1, "One day back"),
            (0, "The calculated date"),
            (1, "One day forward"),
        ]
    }

    var body: some View {
        CVSheet(title: "Adjust Islamic date") {
            VStack(spacing: 0) {
                ForEach(options, id: \.days) { option in
                    Button {
                        onSelect(option.days)
                        dismiss()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: adjustment == option.days ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(adjustment == option.days ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(CVFont.bodyLarge)
                                    .foregroundStyle(adjustment == option.days ? Color.cvPrimary : Color.cvOnSurface)
                                Text(IslamicDate.format(date: Date(), adjustmentDays: option.days))
                                    .font(CVFont.bodyMedium)
                                    .foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
