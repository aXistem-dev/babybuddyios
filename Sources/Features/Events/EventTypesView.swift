import SwiftUI
import SwiftData

/// Settings ▸ Event types: the server's event types, with their emoji, and adding, editing and
/// deleting them as far as the server's `permissions` allow. Online only (see ``EventTypesModel``).
struct EventTypesView: View {
    @Environment(AppSession.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<LocalEntity> { $0.kindRaw == "eventType" }) private var records: [LocalEntity]
    @State private var model = EventTypesModel()
    @State private var editing: EventTypeForm.Target?
    @AppStorage(EventsCapability.permissionsKey, store: SharedDefaults.suite) private var permissionsData: Data?

    private var permissions: EventsCapability.Permissions { EventsCapability.permissions }

    /// The types by name; ones being deleted are left out.
    private var types: [LocalEntity] {
        records.filter { $0.syncState != .pendingDelete }
            .sorted {
                ($0.payloadObject["name"] as? String ?? "")
                    .localizedStandardCompare($1.payloadObject["name"] as? String ?? "") == .orderedAscending
            }
    }

    var body: some View {
        let _ = permissionsData // redraw when a sync changes the permissions
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                    VStack(spacing: 0) {
                        if types.isEmpty {
                            Text("No event types yet.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 15).padding(.vertical, 13)
                        }
                        ForEach(Array(types.enumerated()), id: \.element.localID) { index, type in
                            if index > 0 {
                                Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15)
                            }
                            row(type)
                        }
                    }
                }
                if let footer {
                    Text(footer.text)
                        .font(.caption)
                        .foregroundStyle(footer.isProblem ? BBColor.danger : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.top, 2)
                }
            }
            .padding(.horizontal).padding(.top, 8)
        }
        .background(BBColor.surface)
        .navigationTitle("Event types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if permissions.add {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add event type")
                        .disabled(!model.isOnline)
                }
            }
        }
        .task { await model.refresh(session: session) }
        .refreshable { await model.refresh(session: session) }
        .sheet(item: $editing) { target in
            EventTypeForm(target: target, model: model, permissions: permissions)
        }
    }

    private func row(_ type: LocalEntity) -> some View {
        let name = type.payloadObject["name"] as? String ?? ""
        let emoji = type.payloadObject["emoji"] as? String ?? ""
        let canOpen = (permissions.change || permissions.delete) && model.isOnline
        return Button { editing = .existing(type) } label: {
            HStack(spacing: 12) {
                ActivityTile(kind: .event, size: 30, glyph: 17, emoji: emoji)
                Text(name).font(.body).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if canOpen {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel(name) // a Button is one element already
    }

    private var footer: (text: String, isProblem: Bool)? {
        switch model.status {
        case .refused(let message): return (message, true)
        case .offline: return ("Offline. Event types can only be changed while connected.", false)
        case .idle, .working: return nil
        }
    }
}

/// Adding or editing one event type: its name and an optional emoji. Editing can also delete it.
struct EventTypeForm: View {
    enum Target: Identifiable {
        case new
        case existing(LocalEntity)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let type): return type.localID.uuidString
            }
        }
    }

    @Environment(AppSession.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let target: Target
    let model: EventTypesModel
    let permissions: EventsCapability.Permissions
    @State private var name = ""
    @State private var emoji = ""
    @State private var confirmingDelete = false

    private var existing: LocalEntity? {
        if case .existing(let type) = target { return type }
        return nil
    }
    private var canSave: Bool {
        (existing == nil ? permissions.add : permissions.change) && model.isOnline
            && EventTypeEdit.nameProblem(name) == nil && EventTypeEdit.emojiIsValid(emoji)
            && model.status != .working
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BBCard(cornerRadius: BBRadius.tile) {
                        VStack(alignment: .leading, spacing: 14) {
                            field("Name") {
                                TextField("Name", text: $name)
                                    .disabled(existing != nil && !permissions.change)
                            }
                            field("Emoji (optional)") {
                                TextField("One emoji", text: $emoji)
                                    .disabled(existing != nil && !permissions.change)
                            }
                            if !EventTypeEdit.emojiIsValid(emoji) {
                                Text("Use one emoji, or leave it empty.")
                                    .font(.caption).foregroundStyle(BBColor.danger)
                            }
                            if let slug = existing?.payloadObject["slug"] as? String {
                                Text("The type\u{2019}s key (\(slug)) stays the same when you rename it.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if case .refused(let message) = model.status {
                        Text(message).font(.footnote).foregroundStyle(BBColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    if existing != nil, permissions.delete {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete event type", systemImage: "trash")
                        }
                        .buttonStyle(BBFilledButton(background: BBColor.danger.opacity(0.14), foreground: BBColor.danger))
                        .disabled(!model.isOnline || model.status == .working)
                    }
                }
                .padding(.horizontal).padding(.top, 8)
            }
            .background(BBColor.surface)
            .navigationTitle(existing == nil ? "New event type" : "Edit event type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .alert("Delete this event type?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                if let existing {
                    name = existing.payloadObject["name"] as? String ?? ""
                    emoji = existing.payloadObject["emoji"] as? String ?? ""
                }
            }
        }
    }

    private func field<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(BBColor.nested, in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
        }
    }

    private func save() async {
        let done: Bool
        if let existing {
            done = await model.update(existing, name: name, emoji: emoji, session: session, context: context, sync: sync)
        } else {
            done = await model.create(name: name, emoji: emoji, session: session, context: context, sync: sync)
        }
        if done { dismiss() }
    }

    private func delete() async {
        guard let existing else { return }
        if await model.delete(existing, session: session, context: context, sync: sync) { dismiss() }
    }
}
