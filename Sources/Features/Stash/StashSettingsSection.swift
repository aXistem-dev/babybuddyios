import SwiftUI

/// Settings ▸ Milk stash: the server's stash settings, on a server that has them. Everyone who sees
/// the stash sees them; only a user the server allows (`can_edit`) changes them. Toggles save at
/// once; the hour steppers a moment after the last tap, or when the screen goes. Offline, the last
/// values from the server show read-only.
struct StashSettingsSection: View {
    @Environment(AppSession.self) private var session
    @Environment(SyncEngine.self) private var sync
    @State private var model = StashSettingsModel()
    /// The ages as the steppers show them while a change waits to be sent.
    @State private var warnDraft: Int?
    @State private var maxDraft: Int?
    @State private var pendingAgeSave: Task<Void, Never>?

    /// The longest age the steppers go to: two weeks.
    private let maxHours = 336

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Milk stash")
            BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                VStack(spacing: 0) {
                    if let settings = model.settings {
                        rows(settings)
                    } else {
                        Text(model.status == .offline ? "Offline" : "Loading\u{2026}")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 13)
                    }
                }
                .padding(.horizontal, 15)
            }
            if let footer {
                Text(footer.text)
                    .font(.caption)
                    .foregroundStyle(footer.isProblem ? BBColor.danger : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .task { await model.refresh(session: session) }
        .onDisappear { sendAges() }
    }

    @ViewBuilder private func rows(_ settings: StashSettingsDTO) -> some View {
        let editable = model.isEditable
        SettingsRow(symbol: "tray.and.arrow.down.fill", tint: BBColor.pumping,
                    title: "Store pumping in the stash",
                    subtitle: "Pre-selects Store in stash on new pumping.") {
            Toggle("Store pumping in the stash", isOn: toggle(\.pumping_to_stash, in: settings))
                .labelsHidden().tint(BBColor.primary).disabled(!editable)
        }
        divider
        SettingsRow(symbol: "drop.fill", tint: BBColor.feeding, title: "Bottles from the stash",
                    subtitle: "Pre-selects Taken from stash on new breast-milk feedings once the stash is in use.") {
            Toggle("Bottles from the stash", isOn: toggle(\.bottle_from_stash, in: settings))
                .labelsHidden().tint(BBColor.primary).disabled(!editable)
        }
        divider
        let warn = warnDraft ?? settings.warn_age_hours
        let max = maxDraft ?? settings.max_age_hours
        ageRow("Use first after", subtitle: "Milk this old is marked to use first.",
               symbol: "clock", tint: BBColor.warning, hours: warn, range: 0...Swift.max(0, max - 1),
               editable: editable) { warnDraft = $0; scheduleAges() }
        divider
        ageRow("Throw away after", subtitle: "Milk this old is marked to throw away.",
               symbol: "trash", tint: BBColor.danger, hours: max, range: (warn + 1)...Swift.max(warn + 1, maxHours),
               editable: editable) { maxDraft = $0; scheduleAges() }
    }

    private func ageRow(_ title: String, subtitle: String, symbol: String, tint: Color, hours: Int,
                        range: ClosedRange<Int>, editable: Bool,
                        onChange: @escaping (Int) -> Void) -> some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Text("\(hours) h").font(.body).monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: Binding(get: { hours }, set: onChange), in: range)
                    .labelsHidden()
                    .disabled(!editable)
                    .accessibilityValue("\(hours) hours")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(BBColor.divider).frame(height: 0.5)
    }

    /// A toggle that saves the setting as soon as it flips.
    private func toggle(_ field: WritableKeyPath<StashSettingsDTO, Bool>,
                        in settings: StashSettingsDTO) -> Binding<Bool> {
        Binding(get: { model.settings?[keyPath: field] ?? settings[keyPath: field] }, set: { value in
            guard var new = model.settings else { return }
            new[keyPath: field] = value
            Task { await model.save(new, session: session, sync: sync) }
        })
    }

    /// Send the ages a moment after the last stepper tap, not on every one.
    private func scheduleAges() {
        pendingAgeSave?.cancel()
        pendingAgeSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            sendAges()
        }
    }

    private func sendAges() {
        pendingAgeSave?.cancel()
        guard var new = model.settings, warnDraft != nil || maxDraft != nil else { return }
        if let warnDraft { new.warn_age_hours = warnDraft }
        if let maxDraft { new.max_age_hours = maxDraft }
        warnDraft = nil
        maxDraft = nil
        Task { await model.save(new, session: session, sync: sync) }
    }

    /// Under the card: a refused change's reason, offline, or that only an administrator can change
    /// these.
    private var footer: (text: String, isProblem: Bool)? {
        switch model.status {
        case .refused(let message): return (message, true)
        case .offline: return ("Offline. These are the last values from the server.", false)
        case .idle, .saving:
            if model.settings?.can_edit == false { return ("Only an administrator can change these.", false) }
            return nil
        }
    }
}
