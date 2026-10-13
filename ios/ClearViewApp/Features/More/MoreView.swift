import SwiftUI

/// The More tab — "Tools & protection".
///
/// Placeholder. On Android this tab holds the to-dos, the Dhikr counter, the
/// Phone Limit sheet, the appearance setting, and a nested **Protection** page
/// that carries the whole blocking dashboard behind a passcode. On iOS the
/// blocking work is deliberately last: it depends on an Apple **Family Controls**
/// entitlement that has to be requested and approved, and the plan is not to let
/// that gate everything else. The tools above it — to-dos, Dhikr, Phone Limit —
/// migrate before it.
struct MoreView: View {
    var body: some View {
        NavigationStack {
            ComingSoonView(
                systemImage: "ellipsis",
                title: "More",
                note: "To-dos, Dhikr counter, Phone Limit, appearance — and "
                    + "Protection. Protection is scheduled last; it needs an "
                    + "Apple entitlement."
            )
            .navigationTitle("More")
        }
    }
}

#Preview {
    MoreView()
}
