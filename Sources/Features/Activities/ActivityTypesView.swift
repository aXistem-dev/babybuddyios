import SwiftUI
import SwiftData

/// Settings ▸ Activity types: the server's activity types in its order, with their icons, and adding,
/// editing and deleting them as far as the server's `permissions` allow. Online only (see
/// ``ActivityTypesModel``).
struct ActivityTypesView: View {
    @Environment(AppSession.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<LocalEntity> { $0.kindRaw == "activityType" }) private var records: [LocalEntity]
    @State private var model = ActivityTypesModel()
    @State private var editing: ActivityTypeForm.Target?
    @AppStorage(ActivitiesCapability.permissionsKey, store: SharedDefaults.suite) private var permissionsData: Data?

    private var permissions: ActivitiesCapability.Permissions { ActivitiesCapability.permissions }

    /// The types in the server's order; ones being deleted are left out.
    private var types: [(record: LocalEntity, info: ActivitiesCapability.TypeInfo)] {
        let pairs = records.filter { $0.syncState != .pendingDelete }
            .compactMap { record in ActivitiesCapability.TypeInfo(record).map { (record, $0) } }
        let order = ActivitiesCapability.sorted(pairs.map(\.1)).map(\.id)
        return pairs.sorted { (order.firstIndex(of: $0.1.id) ?? 0) < (order.firstIndex(of: $1.1.id) ?? 0) }
    }

    var body: some View {
        let _ = permissionsData // redraw when a sync changes the permissions
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                    VStack(spacing: 0) {
                        if types.isEmpty {
                            Text("No activity types yet.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 15).padding(.vertical, 13)
                        }
                        ForEach(Array(types.enumerated()), id: \.element.record.localID) { index, type in
                            if index > 0 {
                                Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15)
                            }
                            row(type.record, type.info)
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
        .navigationTitle("Activity types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if permissions.add {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add activity type")
                        .disabled(!model.isOnline)
                }
            }
        }
        .task { await model.refresh(session: session) }
        .refreshable { await model.refresh(session: session) }
        .sheet(item: $editing) { target in
            ActivityTypeForm(target: target, model: model, permissions: permissions)
        }
    }

    private func row(_ record: LocalEntity, _ type: ActivitiesCapability.TypeInfo) -> some View {
        let canOpen = (permissions.change || permissions.delete) && model.isOnline
        let details = [type.hasDuration ? "Start and end" : nil, type.active ? nil : "Inactive"].compactMap { $0 }
        return Button { editing = .existing(record) } label: {
            HStack(spacing: 12) {
                ActivityTile(kind: .activity, size: 30, glyph: 17, icon: type.tileIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type.name).font(.body).foregroundStyle(.primary)
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
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
        .accessibilityLabel(([type.name] + details).joined(separator: ", ")) // a Button is one element already
    }

    private var footer: (text: String, isProblem: Bool)? {
        switch model.status {
        case .refused(let message): return (message, true)
        case .offline: return ("Offline. Activity types can only be changed while connected.", false)
        case .idle, .working: return nil
        }
    }
}

/// Adding or editing one activity type: its name, an optional emoji, its icon, whether it tracks
/// duration, and whether it's offered. Editing can also delete it.
struct ActivityTypeForm: View {
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
    let model: ActivityTypesModel
    let permissions: ActivitiesCapability.Permissions
    @State private var fields = ActivityTypeFields()
    @State private var confirmingDelete = false

    private var existing: LocalEntity? {
        if case .existing(let type) = target { return type }
        return nil
    }
    private var canEdit: Bool { existing == nil ? permissions.add : permissions.change }
    private var canSave: Bool {
        canEdit && model.isOnline && fields.isValid && model.status != .working
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BBCard(cornerRadius: BBRadius.tile) {
                        VStack(alignment: .leading, spacing: 14) {
                            field("Name") { TextField("Name", text: $fields.name) }
                            field("Emoji (optional)") { TextField("One emoji", text: $fields.emoji) }
                            if !fields.emojiIsValid {
                                Text("Use one emoji, or leave it empty.")
                                    .font(.caption).foregroundStyle(BBColor.danger)
                            }
                            iconRow
                            if let slug = existing?.payloadObject["slug"] as? String {
                                Text("The type\u{2019}s key (\(slug)) stays the same when you rename it.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(!canEdit)
                    }
                    BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                        VStack(spacing: 0) {
                            toggleRow("Track duration", isOn: $fields.hasDuration)
                            Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15)
                            toggleRow("Active", isOn: $fields.active)
                        }
                        .disabled(!canEdit)
                    }
                    Text("With Track duration, an activity has a start and an end; without it, one time. Inactive types aren\u{2019}t offered when logging; their activities stay.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    if case .refused(let message) = model.status {
                        Text(message).font(.footnote).foregroundStyle(BBColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    if existing != nil, permissions.delete {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete activity type", systemImage: "trash")
                        }
                        .buttonStyle(BBFilledButton(background: BBColor.danger.opacity(0.14), foreground: BBColor.danger))
                        .disabled(!model.isOnline || model.status == .working)
                    }
                }
                .padding(.horizontal).padding(.top, 8)
            }
            .background(BBColor.surface)
            .navigationTitle(existing == nil ? "New activity type" : "Edit activity type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .alert("Delete this activity type?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            }
            // Activities use it: the server said how many, and this user may delete them with it.
            .alert(model.pendingCascade.map {
                       ActivityTypeFields.cascadeTitle(name: $0.name, activityCount: $0.activityCount)
                   } ?? "",
                   isPresented: Binding(get: { model.pendingCascade != nil },
                                        set: { if !$0 { model.pendingCascade = nil } })) {
                Button("Delete", role: .destructive) { Task { await deleteWithActivities() } }
                Button("Cancel", role: .cancel) { model.pendingCascade = nil }
            } message: {
                Text(ActivityTypeFields.cascadeMessage)
            }
            .onAppear {
                if let existing { fields = ActivityTypeFields(payload: existing.payloadObject) }
            }
        }
    }

    /// The server's fixed icons, shown when the type has no emoji.
    private var iconRow: some View {
        HStack {
            Text("Icon").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Picker("Icon", selection: $fields.icon) {
                ForEach(ActivityIcon.serverIcons, id: \.name) { icon in
                    Label {
                        Text(icon.title)
                    } icon: {
                        ActivityIcon(icon: icon.name, emoji: "").view(18)
                    }
                    .tag(icon.name)
                }
            }
            .pickerStyle(.menu)
            .tint(BBColor.brandAccent)
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

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .tint(BBColor.brandAccent)
            .padding(.horizontal, 15).padding(.vertical, 9)
    }

    private func save() async {
        let done: Bool
        if let existing {
            done = await model.update(existing, to: fields, session: session, context: context, sync: sync)
        } else {
            done = await model.create(fields, session: session, context: context, sync: sync)
        }
        if done { dismiss() }
    }

    private func delete() async {
        guard let existing else { return }
        if await model.delete(existing, session: session, context: context, sync: sync) { dismiss() }
    }

    private func deleteWithActivities() async {
        guard let existing else { return }
        if await model.deleteWithActivities(existing, session: session, context: context, sync: sync) { dismiss() }
    }
}
