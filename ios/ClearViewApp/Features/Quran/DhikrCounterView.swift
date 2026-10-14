import SwiftUI

struct DhikrCounterView: View {
    @State private var model = DhikrCounterModel()
    @State private var showReset = false
    @State private var showManagement = false
    @State private var editing: DhikrItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.visibleItems) { item in
                            CVChip(title: item.name, selected: item.id == model.selectedId) { model.select(id: item.id) }
                        }
                    }
                }
                if model.visibleItems.isEmpty {
                    CVEmptyState(title: "No visible dhikr", message: "Manage your phrases to show a dhikr or add a new one.", symbol: "list.bullet")
                    Button("Manage dhikr") { showManagement = true }.buttonStyle(.borderedProminent)
                }
                if let item = model.selected {
                    VStack(spacing: 12) {
                        Text(item.name).font(.title2.bold())
                        Text(item.arabic).font(.system(size: 38)).multilineTextAlignment(.center)
                        Text(item.translation).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Button {
                        let completion = model.tap()
                        if model.vibrationEnabled {
                            if completion != nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                            else { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(Color.cvSurfaceContainerHigh, lineWidth: 12)
                            Circle().trim(from: 0, to: item.progress)
                                .stroke(Color.cvPrimary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 8) {
                                Text("\(item.count)").font(.system(size: 76, weight: .light, design: .rounded)).monospacedDigit()
                                Text(item.hasTarget ? "of \(item.target)" : "Open count").font(.subheadline)
                                    .foregroundStyle(Color.cvOnSurfaceVariant)
                                Text("TAP TO COUNT").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Color.cvPrimary)
                            }
                        }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 296).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Count \(item.name), \(item.count) of \(item.target)")
                        .accessibilityIdentifier("dhikr.count")
                    HStack {
                        Button { model.step(by: -1) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Previous dhikr")
                        Spacer()
                        Menu("Target: \(item.target)") {
                            ForEach([0, 33, 99, 100, 1000], id: \.self) { target in
                                Button(target == 0 ? "Unlimited" : "\(target)") { model.setTarget(target, id: item.id) }
                            }
                            Button("Custom target & edit") { editing = item }
                        }
                        Spacer()
                        Button { model.step(by: 1) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("Next dhikr")
                    }.padding(.horizontal, 24)
                    if item.lastCompletedCount > 0 {
                        Label("Last completed: \(item.lastCompletedCount)", systemImage: "checkmark.seal")
                            .font(.footnote).foregroundStyle(Color.cvPrimary)
                    }
                }
                Toggle("Haptic feedback", isOn: $model.vibrationEnabled).padding(.horizontal)
            }.padding(20)
        }.background(Color.cvBackground).navigationTitle("Dhikr Counter").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                Button { showReset = true } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Reset count")
                Button { showManagement = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Manage dhikr")
                Button { editing = DhikrItem(id: "", name: "") } label: { Image(systemName: "plus") }.accessibilityLabel("Add dhikr")
            }
            .confirmationDialog("Reset this count?", isPresented: $showReset, titleVisibility: .visible) {
                Button("Reset count", role: .destructive) { model.resetSelection() }
                Button("Reset all counts", role: .destructive) { model.resetAllProgress() }
            }
            .sheet(isPresented: $showManagement) { DhikrManagementView(model: model) }
            .sheet(item: $editing) { item in
                DhikrEditor(item: item) { updated in
                    if updated.id.isEmpty {
                        let identifier = model.add(name: updated.name, arabic: updated.arabic, translation: updated.translation, target: updated.target)
                        model.select(id: identifier)
                    } else { model.update(updated) }
                }
            }
            .onAppear { model.reload() }
    }
}
