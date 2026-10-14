import SwiftUI

struct ProtectionAccessGate<Content: View>: View {
    @State private var model = ProtectionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var entry = ""
    @State private var confirmation = ""
    @State private var error: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if model.isLocked {
                ScrollView {
                    ProtectionLockView(model: model, entry: $entry, confirmation: $confirmation, error: $error).padding(20)
                }.background(Color.cvBackground)
            } else { content() }
        }.onChange(of: scenePhase) { _, phase in
            if phase == .background { model.lock(); entry = ""; confirmation = "" }
        }
    }
}
