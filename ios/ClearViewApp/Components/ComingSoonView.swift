import SwiftUI

/// A screen for a tab whose feature has not been migrated yet.
///
/// It exists so the shell is honest: a tab that opens onto an empty page reads as
/// a bug, while a tab that says what it will hold reads as work in progress. The
/// copy names the Android feature it corresponds to, so nobody has to guess
/// whether something was dropped.
struct ComingSoonView: View {
    let systemImage: String
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.cvOnSurfaceVariant)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.cvOnSurface)

            Text(note)
                .font(.footnote)
                .foregroundStyle(Color.cvOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cvBackground)
    }
}
