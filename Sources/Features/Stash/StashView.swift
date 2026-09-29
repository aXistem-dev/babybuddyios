import SwiftUI
import SwiftData
import Charts

/// The milk stash, on a server that has it: what's in it and how old, adding and discarding milk,
/// how much each child had from it, each parent's pumping, and the stash entries and pumping
/// sessions behind it, each editable. The balance and lots are the server's (``StashViewModel``);
/// everything else is read from the local cache. Pushed from the Home card and `babybuddy://stash`.
struct StashView: View {
    @Environment(SyncEngine.self) private var sync
    /// The child the stash was opened for; editors opened from here start from it.
    let childID: Int

    /// Everything the screen reads from the cache, for every child and parent: the stash is shared.
    @Query private var records: [LocalEntity]
    @State private var model = StashViewModel()
    @State private var editing: LocalEntity?
    @State private var newEntry: StashEntryPreset?
    @State private var entryLimit = 20
    @State private var sessionLimit = 20
    @AppStorage(StashNegativeWarning.dismissedKey, store: SharedDefaults.suite)
    private var warningDismissed = false

    private let aggregator = ChartAggregator()

    init(childID: Int) {
        self.childID = childID
        let kinds = [EntityKind.child, .parent, .pumping, .feeding, .stashAdjustment].map(\.rawValue)
        let pendingDelete = SyncState.pendingDelete.rawValue
        let predicate = #Predicate<LocalEntity> { entity in
            kinds.contains(entity.kindRaw) && entity.syncStateRaw != pendingDelete
        }
        _records = Query(filter: predicate, sort: \LocalEntity.timestamp, order: .reverse)
    }

    var body: some View {
        let summary = model.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if StashNegativeWarning.shows(balance: summary?.balance, dismissed: warningDismissed) {
                    negativeWarning
                }
                balanceCard(summary)
                if let summary, !summary.lots.isEmpty { lotsSection(summary) }
                if !children.isEmpty { useSection }
                if !parents.isEmpty { pumpingSection }
                entriesSection
                sessionsSection
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(BBColor.surface)
        .navigationTitle("Milk stash")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.sync() }
        .onAppear { model.refreshAfterSync() }
        .sheet(item: $editing) { entity in
            EntityEditorView(kind: entity.kind, childID: childID, entity: entity)
        }
        .sheet(item: $newEntry) { preset in
            EntityEditorView(kind: .stashAdjustment, childID: childID, stashPreset: preset)
        }
    }

    // MARK: Below-zero warning

    private var negativeWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(BBColor.danger)
                Text(StashNegativeWarning.message)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            Button("Dismiss") { warningDismissed = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BBColor.brandAccent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BBColor.danger.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
    }

    // MARK: Balance

    private func balanceCard(_ summary: StashSummaryDTO?) -> some View {
        let balance = summary.map { EntityFormatting.formatAmount($0.balance) } ?? "\u{2014}"
        let below = (summary?.balance ?? 0) < 0
        return BBCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In the stash").font(.subheadline).foregroundStyle(.secondary)
                        Text(balance)
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(below ? BBColor.danger : Color.primary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("In the stash, \(balance)")
                    Spacer(minLength: 8)
                    if let summary { StashStatusChip(status: summary.status) }
                }
                if let summary, summary.status != .ok { statusBanner(summary) }
                HStack(spacing: 10) {
                    Button { newEntry = StashEntryPreset(kind: .added) } label: {
                        Label("Add to stash", systemImage: "plus")
                    }
                    .buttonStyle(.bbTinted)
                    Button { newEntry = StashEntryPreset(kind: .discarded) } label: {
                        Label("Discard milk", systemImage: "minus")
                    }
                    .buttonStyle(.bbNeutral)
                }
            }
        }
    }

    /// "Use first" while the oldest milk is getting old, "Throw away" once some is too old.
    private func statusBanner(_ summary: StashSummaryDTO) -> some View {
        let expired = summary.status == .expired
        let color = expired ? BBColor.danger : BBColor.warning
        let oldest = summary.oldest_age_hours.map { " The oldest is \(Int($0)) h old." } ?? ""
        let text = expired
            ? "Throw away: some milk is older than \(Int(summary.max_age_hours)) h.\(oldest)"
            : "Use first: some milk is older than \(Int(summary.warn_age_hours)) h.\(oldest)"
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: expired ? "trash.fill" : "clock.fill")
                .font(.system(size: 13))
                .foregroundStyle(expired ? BBColor.danger : BBColor.warningAccent)
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Lots

    /// The milk left, oldest first, each with its age and state. Only the oldest expired lot offers
    /// "Throw away" (milk is used oldest first); all expired milk can go in one entry.
    private func lotsSection(_ summary: StashSummaryDTO) -> some View {
        let offered = StashThrowAway.lotOffers(summary)
        let anyExpired = summary.lots.contains { $0.status == .expired }
        return VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Milk in the stash")
            BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(summary.lots.enumerated()), id: \.offset) { index, lot in
                        if index > 0 { rowDivider }
                        lotRow(lot, offersThrowAway: lot == offered, maxAgeHours: summary.max_age_hours)
                    }
                }
            }
            if anyExpired {
                Button {
                    newEntry = StashEntryPreset.throwAway(StashThrowAway.allExpiredAmount(summary),
                                                         maxAgeHours: summary.max_age_hours)
                } label: {
                    Label("Throw away all expired milk", systemImage: "trash")
                }
                .buttonStyle(BBFilledButton(background: BBColor.danger.opacity(0.14), foreground: BBColor.danger))
            }
        }
    }

    private func lotRow(_ lot: StashLotDTO, offersThrowAway: Bool, maxAgeHours: Double) -> some View {
        let amount = EntityFormatting.formatAmount(lot.amount)
        let age = "\(Int(lot.age_hours)) h old"
        let from = lot.time.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(amount).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("\(age) · from \(from)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StashStatusChip(status: lot.status)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(amount), \(age), \(lot.status.label)")
            if offersThrowAway {
                Button {
                    newEntry = StashEntryPreset.throwAway(lot.throw_away_amount ?? lot.amount, maxAgeHours: maxAgeHours)
                } label: {
                    Label("Throw away", systemImage: "trash")
                }
                .buttonStyle(BBFilledButton(background: BBColor.danger, foreground: .white))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    // MARK: Per-child use

    /// How much milk each child had from the stash, from the feedings synced to this phone.
    private var useSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("From the stash")
            BBCard(cornerRadius: BBRadius.tile, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.localID) { index, child in
                        if index > 0 { rowDivider }
                        useRow(child)
                    }
                }
            }
        }
    }

    private func useRow(_ child: LocalEntity) -> some View {
        let name = child.payloadObject["first_name"] as? String ?? "Child"
        let totals = child.serverID.map { StashUse.totals(records, childID: $0) } ?? StashUse.Totals(today: 0, week: 0)
        let today = EntityFormatting.formatAmount(totals.today)
        let week = EntityFormatting.formatAmount(totals.week)
        return HStack(spacing: 12) {
            Text(name).font(.body)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Today \(today)").font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("7 days \(week)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(today) from the stash today, \(week) in 7 days")
    }

    // MARK: Pumping per parent

    private var pumpingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Pumping")
            ForEach(parents) { parentCard($0) }
        }
    }

    /// A parent's last session, their last 7 days' total and a bar per day.
    private func parentCard(_ parent: ParentRow) -> some View {
        let series = aggregator.pumpingByDay(records, parentID: parent.id, period: .week)
        let weekTotal = series.reduce(0.0) { $0 + $1.totalAmount }
        let weekCount = series.reduce(0) { $0 + $1.count }
        let last = sessions.first { ($0.payloadObject["parent"] as? Int) == parent.id }
        let lastLine: String = last.map { (session: LocalEntity) -> String in
            let when = session.timestamp.formatted(.relative(presentation: .named))
            let amount = (session.payloadObject["amount"] as? Double).map { ", \(EntityFormatting.formatAmount($0))" } ?? ""
            return "Last pumped \(when)\(amount)"
        } ?? "No pumping synced yet"
        return BBCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ActivityTile(kind: .pumping, size: 30, glyph: 17)
                    Text(parent.name).font(.headline)
                    Spacer(minLength: 8)
                    Text("7 days: \(EntityFormatting.formatAmount(weekTotal))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(lastLine).font(.footnote).foregroundStyle(.secondary)
                if weekCount > 0 {
                    Chart(series) { day in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Amount", day.totalAmount))
                        .foregroundStyle(BBColor.pumping)
                        .cornerRadius(3)
                        .accessibilityLabel(day.day.formatted(.dateTime.month(.abbreviated).day()))
                        .accessibilityValue("\(Int(day.totalAmount)) millilitres")
                    }
                    .chartYAxisLabel("ml")
                    .modifier(DayAxis(period: .week))
                    .frame(height: 140)
                }
            }
        }
    }

    // MARK: Entries and sessions

    private var entriesSection: some View {
        let entries = records.filter { $0.kind == .stashAdjustment }
        return recordList("Stash entries", entries, empty: "No stash entries yet", limit: $entryLimit)
    }

    private var sessionsSection: some View {
        recordList("Pumping sessions", sessions, empty: "No pumping synced yet", limit: $sessionLimit)
    }

    /// Newest first, a page at a time; tapping a row edits it.
    private func recordList(_ title: String, _ items: [LocalEntity], empty: String,
                            limit: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title)
            if items.isEmpty {
                Text(empty)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(Array(items.prefix(limit.wrappedValue))) { item in
                    Button { editing = item } label: { EventRow(entity: item) }
                        .buttonStyle(.plain)
                }
                if items.count > limit.wrappedValue {
                    Button("Show more") { limit.wrappedValue += 20 }
                        .buttonStyle(.bbNeutral)
                        .accessibilityLabel("Show more \(title.lowercased())")
                }
            }
        }
    }

    // MARK: Derived data

    /// A parent, for the per-parent pumping cards.
    struct ParentRow: Identifiable {
        let id: Int
        let name: String
    }

    private var children: [LocalEntity] {
        records.filter { $0.kind == .child }.sorted { $0.timestamp < $1.timestamp }
    }

    private var parents: [ParentRow] {
        records.compactMap { entity -> ParentRow? in
            guard entity.kind == .parent,
                  let id = (entity.payloadObject["id"] as? Int) ?? entity.serverID else { return nil }
            return ParentRow(id: id, name: entity.payloadObject["first_name"] as? String ?? "Parent")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Pumping that belongs to a parent (the stash's milk), newest first.
    private var sessions: [LocalEntity] {
        records.filter { $0.kind == .pumping && ($0.childID == nil || $0.payloadObject["parent"] is Int) }
    }

    private var rowDivider: some View {
        Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15)
    }
}

// MARK: - Status chip

/// A lot's, or the whole stash's, age state: fresh (success), use first (warning), expired (danger).
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

extension StashStatus {
    var label: String {
        switch self {
        case .ok: return "Fresh"
        case .warn: return "Use first"
        case .expired: return "Expired"
        }
    }

    fileprivate var fill: Color {
        switch self {
        case .ok: return BBColor.success
        case .warn: return BBColor.warning
        case .expired: return BBColor.danger
        }
    }

    fileprivate var textColor: Color {
        switch self {
        case .ok: return BBColor.successAccent
        case .warn: return BBColor.warningAccent
        case .expired: return BBColor.danger
        }
    }
}
