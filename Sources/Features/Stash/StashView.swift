import SwiftUI
import SwiftData

/// The milk stash, on a server that has it: how much milk is in it, the milk oldest first with when
/// it expires, and adding, discarding or throwing away expired milk. The figures are the server's as
/// of the last sync; how old the milk is follows the clock. Pushed from the Home card, the Add
/// Activity sheet and `babybuddy://stash`.
struct StashView: View {
    @Environment(SyncEngine.self) private var sync
    /// The child the stash was opened from; the editor needs one, though stash entries have none.
    let childID: Int

    @AppStorage(StashCapability.summaryKey, store: SharedDefaults.suite) private var summaryData: Data?
    /// Milk stash entries the server doesn't have yet. Until it does, its figures leave them out, so
    /// "Throw away expired milk" waits: a second tap would throw away fresh milk too.
    @Query private var queued: [LocalEntity]
    @State private var newEntry: NewStashEntry?

    init(childID: Int) {
        self.childID = childID
        let kind = EntityKind.stashAdjustment.rawValue
        let synced = SyncState.synced.rawValue
        _queued = Query(filter: #Predicate { $0.kindRaw == kind && $0.syncStateRaw != synced })
    }

    var body: some View {
        let summary = StashCapability.summary(from: summaryData)
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                balanceCard(summary, now: now)
                if let summary { lotsSection(summary, now: now) }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(BBColor.surface)
        .navigationTitle("Milk stash")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.sync() }
        .sheet(item: $newEntry) { entry in
            EntityEditorView(kind: .stashAdjustment, childID: childID, stashKind: entry.kind, amount: entry.amount)
        }
    }

    private func balanceCard(_ summary: StashSummaryDTO?, now: Date) -> some View {
        let balance = summary.map { EntityFormatting.formatAmount($0.balance) } ?? "\u{2014}"
        let below = (summary?.balance ?? 0) < 0
        return BBCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In the stash").font(.subheadline).foregroundStyle(.secondary)
                        Text(balance)
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(below ? BBColor.danger : Color.primary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("In the stash, \(balance)")
                    Spacer(minLength: 8)
                    if let summary, !summary.lots.isEmpty { StashStatusChip(status: summary.status(at: now)) }
                }
                if below {
                    Text("More milk was taken out than was put in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { newEntry = NewStashEntry(kind: .added) } label: {
                        Label("Add Milk", systemImage: "plus")
                    }
                    .buttonStyle(.bbTinted)
                    Button { newEntry = NewStashEntry(kind: .discarded) } label: {
                        Label("Discard Milk", systemImage: "minus")
                    }
                    .buttonStyle(.bbNeutral)
                }
            }
        }
    }

    @ViewBuilder private func lotsSection(_ summary: StashSummaryDTO, now: Date) -> some View {
        let expired = (summary.expiredAmount(at: now) * 100).rounded() / 100
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Milk in the stash")
            BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                VStack(spacing: 0) {
                    if summary.lots.isEmpty {
                        Text("No milk in the stash.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 15).padding(.vertical, 13)
                    }
                    ForEach(Array(summary.lots.enumerated()), id: \.offset) { index, lot in
                        if index > 0 { Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15) }
                        lotRow(lot, now: now)
                    }
                }
            }
            if expired > 0 {
                Button { newEntry = NewStashEntry(kind: .discarded, amount: expired) } label: {
                    Label("Throw Away Expired Milk", systemImage: "trash")
                }
                .buttonStyle(BBFilledButton(background: BBColor.danger.opacity(0.14), foreground: BBColor.danger))
                .disabled(!queued.isEmpty)
                if !queued.isEmpty {
                    Text("Waiting to sync the last milk stash entry first.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lotRow(_ lot: StashLotDTO, now: Date) -> some View {
        let amount = EntityFormatting.formatAmount(lot.amount)
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        let detail = "Stored \(lot.time.formatted(format)) · expires \(lot.expires_at.formatted(format))"
        let status = lot.status(at: now)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(amount).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StashStatusChip(status: status)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(amount), \(detail), \(status.label)")
    }
}

/// A new milk stash entry to open the editor on: milk added or discarded, maybe with an amount.
private struct NewStashEntry: Identifiable {
    let id = UUID()
    var kind: StashKind
    var amount: Double?
}

/// "Fresh", "Expiring soon" or "Expired", tinted to match.
struct StashStatusChip: View {
    let status: StashStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.fill.opacity(0.18), in: Capsule())
    }
}

private extension StashStatus {
    var fill: Color {
        switch self {
        case .ok: return BBColor.success
        case .warn: return BBColor.warning
        case .expired: return BBColor.danger
        }
    }

    var textColor: Color {
        switch self {
        case .ok: return BBColor.successAccent
        case .warn: return BBColor.warningAccent
        case .expired: return BBColor.danger
        }
    }
}
