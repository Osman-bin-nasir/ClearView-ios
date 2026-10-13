import SwiftUI

struct DhikrCounterView: View {
    @State private var model = DhikrCounterModel()
    @State private var showReset = false
    @State private var showAdd = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("A MOMENT OF REMEMBRANCE").font(.caption2.weight(.semibold))
                    .tracking(2).foregroundStyle(Color.cvPrimary).padding(.top, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.visibleItems) { item in
                            CVChip(title: item.name, selected: item.id == model.selectedId) { model.select(id: item.id) }
                        }
                    }
                }
                if let item = model.selected {
                    VStack(spacing: 12) {
                        Text(item.arabic).font(.system(size: 38)).multilineTextAlignment(.center)
                        Text(item.name).font(.title2.bold())
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
                        }.frame(width: 260, height: 260).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Count \(item.name), \(item.count) of \(item.target)")
                        .accessibilityIdentifier("dhikr.count")
                    HStack {
                        Button { model.step(by: -1) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Previous dhikr")
                        Spacer()
                        Menu("Target: \(item.target)") {
                            ForEach([0, 33, 99, 100, 1000], id: \.self) { target in
                                Button(target == 0 ? "Unlimited" : "\(target)") { model.setTarget(target, id: item.id) }
                            }
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
            .toolbar {
                Button { showReset = true } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Reset count")
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add dhikr")
            }
            .confirmationDialog("Reset this count?", isPresented: $showReset, titleVisibility: .visible) {
                Button("Reset count", role: .destructive) { model.resetSelection() }
            }
            .alert("Add a dhikr", isPresented: $showAdd) {
                TextField("Name or phrase", text: $name)
                Button("Add") {
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let identifier = model.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        model.select(id: identifier)
                        name = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
