import SwiftUI

struct DhikrManagementView: View {
    @Bindable var model: DhikrCounterModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editing: DhikrItem?
    @State private var deleting: DhikrItem?
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.allItems.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.arabic.contains(search) || $0.translation.localizedCaseInsensitiveContains(search) }) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button { editing = item } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.headline)
                                    Text(item.target == 0 ? "\(item.count) · Unlimited" : "\(item.count) / \(item.target)").font(.caption)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button("Edit", systemImage: "pencil") { editing = item }
                                Button("Move up", systemImage: "arrow.up") { model.move(id: item.id, by: -1) }
                                Button("Move down", systemImage: "arrow.down") { model.move(id: item.id, by: 1) }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                            } label: { Image(systemName: "ellipsis") }
                        }
                        Toggle("Show in counter", isOn: Binding(get: { model.allItems.first { $0.id == item.id }?.visible ?? false }, set: { model.setVisible($0, id: item.id) }))
                        if item.lastCompletedCount > 0 { Text("Last completed: \(item.lastCompletedCount)").font(.caption).foregroundStyle(Color.cvPrimary) }
                    }
                }
                Section {
                    Button("Restore default phrases and reset everything", role: .destructive) { restoring = true }
                }
            }.searchable(text: $search, prompt: "Search dhikr")
                .navigationTitle("Manage dhikr").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { editing = DhikrItem(id: "", name: "") } label: { Image(systemName: "plus") } }
                }
                .sheet(item: $editing) { item in
                    DhikrEditor(item: item) { updated in
                        if updated.id.isEmpty {
                            let identifier = model.add(name: updated.name, arabic: updated.arabic, translation: updated.translation, target: updated.target)
                            model.select(id: identifier)
                        } else { model.update(updated) }
                    }
                }
                .confirmationDialog("Delete this dhikr and its progress?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { if let deleting { model.remove(id: deleting.id) }; deleting = nil }
                }
                .confirmationDialog("Remove custom phrases and all progress?", isPresented: $restoring, titleVisibility: .visible) {
                    Button("Restore defaults", role: .destructive) { model.resetEverything(); model.reload() }
                }
        }.tint(.cvPrimary)
    }
}

struct DhikrEditor: View {
    @State var item: DhikrItem
    var onSave: (DhikrItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target = "33"

    var body: some View {
        NavigationStack {
            Form {
                Section("Phrase") {
                    TextField("Name", text: $item.name)
                    TextField("Arabic (optional)", text: $item.arabic, axis: .vertical)
                    TextField("Translation (optional)", text: $item.translation, axis: .vertical)
                }
                Section("Target") {
                    TextField("Repetitions", text: $target).keyboardType(.numberPad)
                    Text("Use 0 for unlimited counting. Editing preserves your count and completion history.").font(.footnote)
                }
            }.navigationTitle(item.id.isEmpty ? "Add dhikr" : "Edit dhikr").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            item.target = Int(target) ?? 33
                            onSave(item)
                            dismiss()
                        }.disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(target).map { !(0...1_000_000).contains($0) } != false)
                    }
                }
                .onAppear { target = String(item.target) }
        }.tint(.cvPrimary)
    }
}
