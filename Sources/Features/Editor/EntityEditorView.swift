import SwiftUI
import SwiftData
import PhotosUI

/// Adaptive create/edit form for any ``EntityKind``. Reads/writes a JSON payload through
/// ``LocalRepository`` and triggers a sync on save. Renders only the fields relevant to
/// the kind being edited, styled to the Baby Buddy design system (grouped white cards on a
/// soft surface, tinted activity pills, value-pill time fields, brand-blue tag autocomplete).
struct EntityEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(LiveActivityManager.self) private var liveActivity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let childID: Int
    /// nil → creating a new record; non-nil → editing.
    let entity: LocalEntity?
    /// Set when this editor is converting a stopped timer into an activity. Pre-fills
    /// start = timer.start, end = its Stop, and routes Save through ``LocalRepository/convertTimer``.
    let sourceTimer: LocalEntity?
    /// Set when logging the next dose from a medication reminder: a new record pre-filled from this
    /// one, timed now.
    let template: LocalEntity?
    /// Where a new record's `Activity.logged` says it came from.
    let source: Analytics.ActivitySource
    /// What a new stash entry starts with (its kind, and for a throw-away the amount and reason).
    let stashPreset: StashEntryPreset?

    /// The record kind. Mirrored into state so the top activity selector can swap it while
    /// creating; locked to the passed-in value when editing or converting.
    @State private var kind: EntityKind

    /// Which baby this record is filed under. Starts at `childID`; editing an existing record
    /// lets it be reassigned to any other child in the family (``showsChildPicker``).
    @State private var selectedChildID: Int
    @Query(filter: #Predicate<LocalEntity> { $0.kindRaw == "child" }, sort: \.timestamp)
    private var children: [LocalEntity]

    init(kind: EntityKind, childID: Int, entity: LocalEntity? = nil, sourceTimer: LocalEntity? = nil,
         template: LocalEntity? = nil, source: Analytics.ActivitySource = .editor,
         stashPreset: StashEntryPreset? = nil) {
        self.childID = childID
        self.entity = entity
        self.sourceTimer = sourceTimer
        self.template = template
        self.source = source
        self.stashPreset = stashPreset
        _kind = State(initialValue: kind)
        _selectedChildID = State(initialValue: childID)
    }

    // Common fields
    @State private var start = Date()
    @State private var end = Date()
    @State private var time = Date()
    @State private var date = Date()
    @State private var notes = ""
    @State private var tagNames: [String] = []
    // Feeding
    @State private var feedingType: FeedingType = .breastMilk
    @State private var feedingMethod: FeedingMethod = .leftBreast
    @State private var amount = ""
    // Diaper
    @State private var wet = true
    @State private var solid = false
    @State private var color: DiaperColor?
    // Sleep / tummy time
    @State private var nap = false
    @State private var milestone = ""
    // Note
    @State private var noteText = ""
    /// URL of an image already attached to the note (server URL, or a local `file://` preview of a
    /// queued upload). Shown when no new image has been picked in this session.
    @State private var imageURL: String?
    /// A newly picked note image, pending save: the selection item, its decoded preview, and the
    /// re-encoded JPEG bytes to enqueue for upload.
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var pickedImageData: Data?
    // Measurement
    @State private var value = ""
    /// Temperatures are typed, and saved, in the phone's unit.
    private let unit = TemperatureUnit.current
    // Medication
    @State private var medName = ""
    @State private var dosage = ""
    @State private var dosageUnit = "mg"
    @State private var doseInterval: DoseInterval = .none
    @State private var customDoseHours = ""
    @State private var customDoseMinutes = ""
    // On a server with the milk stash: who pumped (or breastfed), and how much went into the stash
    // (pumping) or came out of it (a breast-milk bottle).
    @State private var parentID: Int?
    @State private var toStash = true
    /// Millilitres put into, or taken from, the stash; follows the amount until edited under "More".
    @State private var storedAmount = ""
    @State private var showsStashDetails = false
    // Feeding, on a server with the milk stash: a bottle taken from the stash, and any of it discarded.
    @State private var fromStash = false
    @State private var discardsSome = false
    @State private var discardedAmount = ""
    @State private var discardReason = ""
    // Stash entry (a stash adjustment), on a server with the milk stash.
    @State private var stashKind: StashKind = .added
    @State private var stashReason = ""
    /// The bottle a linked discard belongs to, opened from "Edit on the feeding".
    @State private var linkedFeeding: LocalEntity?

    /// Every cached dose, so a dose synced in while the editor is open still raises the warning.
    @Query(filter: #Predicate<LocalEntity> { $0.kindRaw == "medication" }) private var medications: [LocalEntity]
    /// The cached parents, for "Who pumped" and "Breastfed by" on a server with the milk stash.
    @Query(filter: #Predicate<LocalEntity> { $0.kindRaw == "parent" }) private var parents: [LocalEntity]

    @State private var confirmingDelete = false
    /// The queued write for this record that the server refused, if any. Drives the sync banner.
    @State private var blockedMutation: PendingMutation?
    @State private var showingPending = false

    private var isEditing: Bool { entity != nil }
    private var isConverting: Bool { sourceTimer != nil }
    /// A bottle's linked discard: shown read-only, since it's changed on the bottle.
    private var isLinkedStashEntry: Bool { kind == .stashAdjustment && entity?.isLinkedStashDiscard == true }

    private var navTitle: String {
        if isConverting { return "Convert to \(kind.displayName)" }
        return "\(isEditing ? "Edit" : "New") \(kind.displayName)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if kind == .timer || kind == .child {
                        Text("Not editable here.").foregroundStyle(.secondary)
                    } else {
                        editorContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(BBColor.surface)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid || isLinkedStashEntry).tint(BBColor.brandAccent)
                }
            }
            // `.alert`, not `confirmationDialog` — iOS 26 anchors the latter to its source as a
            // popover and drops the cancel action, leaving a destructive prompt with no way back.
            .alert("Delete this \(kind.displayName.lowercased())?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: populate)
            .onAppear(perform: loadBlockedMutation)
            .sheet(isPresented: $showingPending) {
                PendingChangesView(highlight: blockedMutation?.localID)
            }
            .sheet(item: $linkedFeeding) { feeding in
                EntityEditorView(kind: .feeding, childID: feeding.childID ?? childID, entity: feeding)
            }
        }
    }

    /// Why this record is stuck in the sync queue, when it is. Tapping it opens Pending Changes
    /// on that row, where Retry, Discard, and (for a stale timer) Create without timer live.
    @ViewBuilder private var syncErrorBanner: some View {
        if let blockedMutation, let message = blockedMutation.lastError {
            Button { showingPending = true } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BBColor.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couldn\u{2019}t sync")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BBColor.danger)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(blockedMutation.isStaleTimer
                             ? "Retry, discard, or create without the timer in Pending Changes"
                             : "Fix it here and save, or retry or discard in Pending Changes")
                            .font(.caption)
                            .foregroundStyle(BBColor.danger)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BBColor.danger)
                }
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(BBColor.danger.opacity(scheme == .dark ? 0.16 : 0.10),
                            in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Couldn\u{2019}t sync. \(message). Opens Pending Changes.")
        }
    }

    private func loadBlockedMutation() {
        guard let localID = entity?.localID else { return }
        let all = (try? context.fetch(FetchDescriptor<PendingMutation>())) ?? []
        blockedMutation = all.first { $0.localID == localID && $0.isBlocked }
    }

    /// The editor's scrolling content: the activity selector (while creating, so the customer can
    /// switch kinds without reopening the editor) above the form itself.
    @ViewBuilder private var editorContent: some View {
        if showsActivitySelector { activitySelector }
        formSections
    }

    /// The editable form (everything below the activity selector).
    @ViewBuilder private var formSections: some View {
        syncErrorBanner
        babySection
        sectioned("When") { whenCard }
        sectioned(detailsTitle) { detailsCard }
            // The stash amount tracks the amount until it's changed on its own.
            .onChange(of: amount) { old, new in
                if storedAmount == old { storedAmount = new }
            }
            // The amount stored or taken sits under "More": open it when that's what blocks Save.
            .onChange(of: problem) { _, new in
                if new == .storedAmountInvalid || new == .stashTakenInvalid { showsStashDetails = true }
            }
        if !isLinkedStashEntry {
            sectioned("Tags") { tagsCard }
            if showsNotes { sectioned("Notes") { notesCard } }
            doseWarning
            overlapWarning
            validationNotice
            actionButtons.padding(.top, 4)
        }
    }

    // MARK: Layout helpers

    private func sectioned<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title)
            content()
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(BBColor.divider).frame(height: 0.5).padding(.leading, 15)
    }

    // MARK: Activity selector

    private let quickKinds: [EntityKind] = [.feeding, .change, .sleep, .tummyTime, .pumping, .note]
    private var showsActivitySelector: Bool {
        !isEditing && !isConverting && quickKinds.contains(kind)
    }

    private var activitySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickKinds) { activityPill($0) }
            }
            .padding(.horizontal, 2)
        }
    }

    private func activityPill(_ k: EntityKind) -> some View {
        let selected = k == kind
        let accent = BBColor.activity(k)
        return HStack(spacing: 6) {
            k.icon(15)
            Text(shortName(k)).font(.subheadline.weight(selected ? .semibold : .medium))
        }
        .foregroundStyle(selected ? Color.white : accent)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background {
            Capsule().fill(selected ? accent : accent.opacity(scheme == .dark ? 0.22 : 0.15))
        }
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { kind = k } }
    }

    private func shortName(_ k: EntityKind) -> String {
        switch k {
        case .feeding: return "Feeding"
        case .change: return "Diaper"
        case .sleep: return "Sleep"
        case .tummyTime: return "Tummy"
        case .pumping: return "Pump"
        case .note: return "Note"
        default: return k.displayName
        }
    }

    // MARK: Baby card

    /// Reassigning is only meaningful once a record exists (there's nothing to move yet while
    /// creating) and only offered when the family has more than one child to move it to — the
    /// same gate the Dashboard/Settings child switcher uses.
    private var showsChildPicker: Bool { isEditing && children.count > 1 }

    @ViewBuilder private var babySection: some View {
        if showsChildPicker {
            sectioned("Baby") {
                BBCard(cornerRadius: BBRadius.tile, padding: 0) { childRow }
            }
        }
    }

    private func childDisplayName(_ child: LocalEntity) -> String {
        let p = child.payloadObject
        let parts = [p["first_name"] as? String, p["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unnamed" : parts.joined(separator: " ")
    }

    private var selectedChildName: String {
        children.first { $0.serverID == selectedChildID }.map(childDisplayName) ?? "—"
    }

    private var childRow: some View {
        HStack {
            Text("Baby").font(.body)
            Spacer()
            Menu {
                ForEach(children, id: \.serverID) { child in
                    if let id = child.serverID {
                        Button { selectedChildID = id } label: {
                            menuLabel(childDisplayName(child), checked: id == selectedChildID)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedChildName)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(BBColor.brandAccent)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    // MARK: When card

    private var whenCard: some View {
        BBCard(cornerRadius: BBRadius.tile, padding: 0) {
            VStack(spacing: 0) {
                switch kind {
                case .feeding, .sleep, .tummyTime, .pumping:
                    pickerRow("Start", selection: $start, components: [.date, .hourAndMinute])
                    rowDivider
                    endRow
                case .change, .note, .temperature, .medication:
                    pickerRow("Time", selection: $time, components: [.date, .hourAndMinute])
                case .weight, .height, .headCircumference, .bmi:
                    pickerRow("Date", selection: $date, components: .date)
                case .stashAdjustment:
                    if isLinkedStashEntry {
                        readOnlyRow("Time", time.formatted(date: .abbreviated, time: .shortened))
                            .padding(.horizontal, 15).padding(.vertical, 11)
                    } else {
                        pickerRow("Time", selection: $time, components: [.date, .hourAndMinute])
                    }
                case .timer, .child, .parent:
                    EmptyView()
                }
            }
        }
    }

    private func pickerRow(_ label: String, selection: Binding<Date>,
                           components: DatePickerComponents) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(BBColor.brandAccent)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private var endRow: some View {
        HStack {
            Text("End").font(.body)
            Spacer()
            if end > start {
                Text(EntityFormatting.formatInterval(end.timeIntervalSince(start)))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            DatePicker("", selection: $end, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(BBColor.brandAccent)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    // MARK: Details card (type-specific)

    private var detailsTitle: String { kind == .note ? "Note" : "Details" }

    @ViewBuilder private var detailsCard: some View {
        switch kind {
        case .feeding: feedingDetails
        case .change: changeDetails
        case .sleep:
            BBCard(cornerRadius: BBRadius.tile, padding: 0) { toggleRow("Nap", isOn: $nap) }
        case .tummyTime:
            BBCard(cornerRadius: BBRadius.tile) {
                TextField("Milestone", text: $milestone, axis: .vertical).lineLimit(1...3)
            }
        case .pumping: pumpingDetails
        case .note:
            BBCard(cornerRadius: BBRadius.tile) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Add a note…", text: $noteText, axis: .vertical)
                        .lineLimit(3...8)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    notePhoto
                }
            }
        case .weight, .height, .headCircumference, .bmi:
            BBCard(cornerRadius: BBRadius.tile) {
                fieldLabeled(measurementLabel) { numericField(text: $value, unit: nil) }
            }
        case .temperature:
            BBCard(cornerRadius: BBRadius.tile) {
                VStack(alignment: .leading, spacing: 12) {
                    fieldLabeled("Temperature") { numericField(text: $value, unit: unit.symbol) }
                    unitHint
                }
            }
        case .medication:
            medicationDetails
        case .stashAdjustment:
            stashEntryDetails
        case .timer, .child, .parent:
            EmptyView()
        }
    }

    /// A stash entry: milk added to the stash from elsewhere, or discarded, with an optional reason.
    /// "Whose milk" only when there are several parents to choose from: with one, the server fills
    /// it in. A bottle's linked discard is shown read-only, with a way to its bottle.
    @ViewBuilder private var stashEntryDetails: some View {
        if let entity, entity.isLinkedStashDiscard {
            linkedStashDetails(entity)
        } else {
            BBCard(cornerRadius: BBRadius.tile) {
                VStack(alignment: .leading, spacing: 16) {
                    fieldLabeled("Kind") {
                        BBSegmentedControl(selection: $stashKind, options: StashKind.allCases) { $0.label }
                    }
                    fieldLabeled("Amount") { amountStepper }
                    fieldLabeled("Reason (optional)") {
                        insetField(TextField("Reason (optional)", text: $stashReason))
                    }
                    if parentChoices.count >= 2 {
                        fieldLabeled("Whose milk") { parentPicker(parentChoices, none: "None") }
                    }
                }
            }
        }
    }

    private func linkedStashDetails(_ entry: LocalEntity) -> some View {
        let p = entry.payloadObject
        let amountText = (p["amount"] as? Double).map(EntityFormatting.formatAmount) ?? "\u{2014}"
        let reason = p["reason"] as? String ?? ""
        let feeding = entry.stashFeedingID.flatMap { LocalStore.fetch(kind: .feeding, serverID: $0, in: context) }
        return BBCard(cornerRadius: BBRadius.tile) {
            VStack(alignment: .leading, spacing: 14) {
                readOnlyRow("Kind", stashKind.label)
                readOnlyRow("Amount", amountText)
                readOnlyRow("Reason", reason.isEmpty ? "None" : reason)
                Text("This was discarded from a bottle taken from the stash, so it changes with that feeding.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { linkedFeeding = feeding } label: {
                    Label("Edit on the feeding", systemImage: "drop.fill")
                }
                .buttonStyle(.bbTinted)
                .disabled(feeding == nil)
            }
        }
    }

    /// A label and a value that can't be changed here.
    private func readOnlyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Upstream's type, method and amount, unless the server has the milk stash: then a breastfeed
    /// says which parent gave it when the child has several, and a breast-milk bottle whether it was
    /// taken from the stash and how much of it was discarded.
    private var feedingDetails: some View {
        let capable = StashCapability.isSupported
        let breastfedBy = linkedParentChoices
        return BBCard(cornerRadius: BBRadius.tile) {
            VStack(alignment: .leading, spacing: 16) {
                fieldLabeled("Type") {
                    BBSegmentedControl(selection: $feedingType,
                                       options: FeedingType.allCases) { $0.shortLabel }
                }
                fieldLabeled("Method") {
                    menuField(options: FeedingMethod.allCases, selection: $feedingMethod) { $0.label }
                }
                if capable, Self.breastMethods.contains(feedingMethod), breastfedBy.count >= 2 {
                    fieldLabeled("Breastfed by") { parentPicker(breastfedBy, none: "None") }
                }
                fieldLabeled("Amount") { amountStepper }
                if capable, Self.isStashBottle(type: feedingType, method: feedingMethod) {
                    Toggle(isOn: $fromStash) { Text("Taken from stash").font(.body) }
                        .tint(BBColor.primary)
                    if fromStash {
                        stashAmountDetails("Amount from stash")
                        Toggle(isOn: $discardsSome) { Text("Some was discarded").font(.body) }
                            .tint(BBColor.primary)
                        if discardsSome {
                            fieldLabeled("Amount discarded") { amountField($discardedAmount) }
                            fieldLabeled("Reason (optional)") {
                                insetField(TextField("Reason (optional)", text: $discardReason,
                                                     prompt: Text("Spilled, left over…")))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Upstream's amount alone, unless the server has the milk stash: then the pumping is logged on
    /// a parent, with a switch for whether it went into the stash and, under "More", how much of it.
    private var pumpingDetails: some View {
        let capable = StashCapability.isSupported
        return BBCard(cornerRadius: BBRadius.tile) {
            VStack(alignment: .leading, spacing: 16) {
                if capable, !parentChoices.isEmpty {
                    fieldLabeled("Who pumped") { parentPicker(parentChoices, none: nil) }
                }
                fieldLabeled("Amount") { amountStepper }
                if capable {
                    Toggle(isOn: $toStash) { Text("Store in stash").font(.body) }
                        .tint(BBColor.primary)
                    if toStash { stashAmountDetails("Amount stored") }
                }
            }
        }
    }

    /// "More" under a stash switch: how much of the amount went into, or came out of, the stash.
    /// Starts at the amount, and follows it until changed on its own.
    private func stashAmountDetails(_ label: String) -> some View {
        DisclosureGroup("More", isExpanded: $showsStashDetails) {
            fieldLabeled(label) { amountField($storedAmount) }
                .padding(.top, 8)
                .onAppear { if storedAmount.isEmpty { storedAmount = amount } }
        }
        .tint(BBColor.brandAccent)
    }

    /// The cached parents by first name, for "Who pumped".
    private var parentChoices: [(id: Int, name: String)] {
        parents.compactMap { entity -> (id: Int, name: String)? in
            guard entity.syncState != .pendingDelete,
                  let id = (entity.payloadObject["id"] as? Int) ?? entity.serverID else { return nil }
            return (id: id, name: entity.payloadObject["first_name"] as? String ?? "")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The cached parents linked to this child, for "Breastfed by".
    private var linkedParentChoices: [(id: Int, name: String)] {
        let linked = EntityVisibility.parentIDs(forChild: childID, in: parents)
        return parentChoices.filter { linked.contains($0.id) }
    }

    /// A segment per parent, or a menu when there are too many to fit. With a `none` label, a first
    /// option clears the choice; without one, nothing is selected when the child has several
    /// parents and the entry isn't one of theirs yet.
    @ViewBuilder private func parentPicker(_ choices: [(id: Int, name: String)], none: String?) -> some View {
        let options: [Int?] = (none == nil ? [] : [Int?.none]) + choices.map { Optional($0.id) }
        let name: (Int?) -> String = { id in
            if id == nil, let none { return none }
            return choices.first { $0.id == id }?.name ?? "Choose"
        }
        if options.count <= 3 {
            BBSegmentedControl(selection: $parentID, options: options, label: name)
        } else {
            menuField(options: options, selection: $parentID, label: name)
        }
    }

    private var changeDetails: some View {
        BBCard(cornerRadius: BBRadius.tile, padding: 0) {
            VStack(spacing: 0) {
                toggleRow("Wet", isOn: $wet)
                rowDivider
                toggleRow("Solid", isOn: $solid)
                rowDivider
                colorRow
            }
        }
    }

    /// A typed reading that the range rule would read as the other unit, with the value converted:
    /// 101.3 on a °C phone is Fahrenheit. It's only advice, so Save still stores what was typed.
    @ViewBuilder private var unitHint: some View {
        if let typed = ActivityDraft.number(value), typed > 0, unit.unit(ofStored: typed) != unit {
            let other = unit.unit(ofStored: typed)
            let converted = unit.convert(typed, from: other)
            let fever = SickMode.isFever(converted, line: SickMode.feverLine(in: unit))
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BBColor.warning.opacity(0.45))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BBColor.warningAccent)
                        }
                    Text("\(value.trimmingCharacters(in: .whitespaces)) looks like \(other.name). In \(unit.name) that's \(TemperatureUnit.decimal(converted))°\(fever ? ", over your fever line." : ".")")
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button { value = TemperatureUnit.decimal(converted) } label: {
                    Text("Use \(unit.format(converted))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BBColor.brandAccent)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(BBColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(BBColor.warning.opacity(scheme == .dark ? 0.16 : 0.18),
                        in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
        }
    }

    private var medicationDetails: some View {
        BBCard(cornerRadius: BBRadius.tile) {
            VStack(alignment: .leading, spacing: 16) {
                fieldLabeled("Name") { plainField("Name", text: $medName) }
                fieldLabeled("Dosage") {
                    HStack(spacing: 10) {
                        numericField(text: $dosage, unit: nil)
                        plainField("Unit", text: $dosageUnit).frame(width: 92)
                    }
                }
                fieldLabeled("Next dose after") {
                    menuField(options: [.none] + MedicationReminderPolicy.choices.map(DoseInterval.preset) + [.custom],
                              selection: $doseInterval) { $0.label }
                    if doseInterval == .custom {
                        HStack(spacing: 10) {
                            numericField(text: $customDoseHours, unit: "h")
                            numericField(text: $customDoseMinutes, unit: "m")
                        }
                    }
                }
            }
        }
    }

    // MARK: Field building blocks

    private func fieldLabeled<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            content()
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(label).font(.body) }
            .tint(BBColor.primary)
            .padding(.horizontal, 15).padding(.vertical, 7)
    }

    private var colorRow: some View {
        HStack {
            Text("Color").font(.body)
            Spacer()
            Menu {
                Button { color = nil } label: { menuLabel("None", checked: color == nil) }
                ForEach(DiaperColor.allCases, id: \.self) { c in
                    Button { color = c } label: { menuLabel(c.label, checked: color == c) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(color?.label ?? "None")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(BBColor.brandAccent)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private func menuField<T: Hashable>(options: [T], selection: Binding<T>,
                                        label: @escaping (T) -> String) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { selection.wrappedValue = option } label: {
                    menuLabel(label(option), checked: option == selection.wrappedValue)
                }
            }
        } label: {
            HStack {
                Text(label(selection.wrappedValue)).font(.body)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(BBColor.brandAccent)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BBColor.nested, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(BBColor.fieldStroke, lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder private func menuLabel(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func plainField(_ placeholder: String, text: Binding<String>) -> some View {
        insetField(TextField(placeholder, text: text))
    }

    /// The inset, hairline-bordered look of the editor's text inputs.
    private func insetField<Field: View>(_ field: Field) -> some View {
        field
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(BBColor.nested, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(BBColor.fieldStroke, lineWidth: 0.5)
            }
    }

    /// An inset numeric input with a large tabular figure and optional unit suffix.
    private func numericField(text: Binding<String>, unit: String?) -> some View {
        HStack(spacing: 6) {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .font(.title3.weight(.semibold)).monospacedDigit()
            if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(BBColor.nested, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(BBColor.fieldStroke, lineWidth: 0.5)
        }
    }

    private var amountStepper: some View { amountField($amount) }

    /// Amount = grouped large value + "ml", with a neutral "−" and a brand-blue "+".
    private func amountField(_ text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .fixedSize()
                Text("ml").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BBColor.nested, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(BBColor.fieldStroke, lineWidth: 0.5)
            }

            stepperButton(system: "minus", tint: false) { adjust(text, by: -5) }
            stepperButton(system: "plus", tint: true) { adjust(text, by: 5) }
        }
    }

    private func stepperButton(system: String, tint: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(tint ? BBColor.brandAccent : Color.secondary)
                .background(tint ? BBColor.brandTint : BBColor.controlFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func adjust(_ text: Binding<String>, by delta: Double) {
        let next = max(0, (ActivityDraft.number(text.wrappedValue) ?? 0) + delta)
        text.wrappedValue = trimmed(next)
    }

    // MARK: Tags & notes cards

    private var tagsCard: some View {
        BBCard(cornerRadius: BBRadius.tile) { TagField(selected: $tagNames) }
    }

    private var showsNotes: Bool {
        switch kind {
        case .tummyTime, .note, .timer, .child: return false
        default: return true
        }
    }

    private var notesCard: some View {
        BBCard(cornerRadius: BBRadius.tile) {
            TextField("Add a note…", text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        }
    }

    // MARK: Action buttons

    /// Whether a "Start timer instead" action makes sense — only when creating a fresh
    /// feeding/sleep/tummy record (the kinds that map to a quick-start ``TimerActivity``).
    private var timerActivity: TimerActivity? {
        guard !isEditing, !isConverting else { return nil }
        switch kind {
        case .feeding: return .feeding
        case .sleep: return .sleep
        case .tummyTime: return .tummyTime
        default: return nil
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: save) {
                Label("Save \(kind.displayName)",
                      systemImage: isConverting ? "arrow.triangle.merge" : "checkmark")
            }
            .buttonStyle(.bbPrimary)
            .disabled(!isValid)

            if let activity = timerActivity {
                Button { startTimer(activity) } label: {
                    Label("Start timer instead", systemImage: "play.fill")
                }
                .buttonStyle(BBFilledButton(background: BBColor.brandTint, foreground: BBColor.brandAccent))
            }

            if isEditing {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete \(kind.displayName)", systemImage: "trash")
                }
                .buttonStyle(BBFilledButton(background: BBColor.danger, foreground: .white))
            }
        }
    }

    // MARK: Validation

    /// The form's current contents, handed to ``ActivityDraft`` so the Baby Buddy rules the client
    /// can check offline live in one testable place instead of a boolean inside the view.
    private var draft: ActivityDraft {
        let capable = StashCapability.isSupported
        return ActivityDraft(kind: kind, start: start, end: end, time: time, date: date,
                             amount: amount, value: value, dosage: dosage,
                             noteText: noteText, medName: medName,
                             parentID: parentID, requiresParent: capable, hasParents: !parentChoices.isEmpty,
                             storesInStash: capable && toStash,
                             takesFromStash: capable && fromStash
                                 && Self.isStashBottle(type: feedingType, method: feedingMethod),
                             stashAmount: storedAmount, discardsSome: discardsSome,
                             discardedAmount: discardedAmount)
    }

    private var problem: ActivityProblem? { draft.problem }
    private var isValid: Bool { problem == nil }

    /// Why Save is disabled, inline above the Save button. Amber rather than red: nothing has gone
    /// wrong yet, the entry just isn't something the server will take.
    @ViewBuilder private var validationNotice: some View {
        if let problem {
            warningNotice(problem.message, accessibilityLabel: "Can\u{2019}t save yet. \(problem.message)")
        }
    }

    /// A new dose of a medication whose next dose isn't OK yet — someone may have just given one
    /// on another phone. A warning, not a block: Save stays enabled.
    @ViewBuilder private var doseWarning: some View {
        if kind == .medication, !isEditing,
           let wait = MedicationReminderPolicy.doseNotYetOK(named: medName, childID: childID, in: medications) {
            let given = wait.dose.timestamp.formatted(date: .omitted, time: .shortened)
            let next = wait.next.formatted(date: .omitted, time: .shortened)
            let message = "\(medName.trimmingCharacters(in: .whitespaces)) was last given at \(given). Next dose OK at \(next)."
            warningNotice(message, accessibilityLabel: "Warning. \(message)")
        }
    }

    /// The cached entry of the same kind this one would overlap, which the server refuses to save
    /// alongside it. A warning, not a block: the cache can be stale, and the user may mean to fix
    /// the other entry afterwards.
    @ViewBuilder private var overlapWarning: some View {
        if let other = overlappingRecord, let period = ActivityDraft.period(of: other) {
            let message = "Overlaps the \(period.formatted(.interval.hour().minute())) \(kind.displayName.lowercased()). Baby Buddy won\u{2019}t accept both."
            warningNotice(message, accessibilityLabel: "Warning. \(message)")
        }
    }

    /// Fetched rather than queried, so only records that could intersect are read: upstream caps a
    /// period at 24 hours, so anything starting earlier than that has already ended.
    private var overlappingRecord: LocalEntity? {
        guard ActivityDraft.overlapCheckedKinds.contains(kind) else { return nil }
        let kindRaw = kind.rawValue, child = Optional(childID)
        let earliest = start.addingTimeInterval(-24 * 3600), latest = end
        let candidates = (try? context.fetch(FetchDescriptor<LocalEntity>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.childID == child && $0.timestamp >= earliest && $0.timestamp < latest
        }))) ?? []
        return ActivityDraft.overlapping(kind: kind, childID: childID, start: start, end: end,
                                         excluding: entity?.localID, in: candidates)
    }

    private func warningNotice(_ message: String, accessibilityLabel: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(BBColor.warning)
            Text(message)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(BBColor.warning.opacity(scheme == .dark ? 0.16 : 0.18),
                    in: RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var measurementLabel: String {
        switch kind {
        case .weight: return "Weight"
        case .height: return "Height"
        case .headCircumference: return "Head circumference"
        case .bmi: return "BMI"
        default: return "Value"
        }
    }

    // MARK: Note photo

    private var hasNoteImage: Bool { pickedImage != nil || imageURL != nil }

    @ViewBuilder private var notePhoto: some View {
        if let pickedImage {
            notePreview(Image(uiImage: pickedImage))
        } else if let imageURL {
            RemoteImage(urlString: imageURL) {
                RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous)
                    .fill(BBColor.controlFill)
                    .frame(height: 160)
                    .overlay(ProgressView())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
        }
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label(hasNoteImage ? "Change Photo" : "Add Photo", systemImage: "photo")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(BBColor.brandAccent)
        }
        .onChange(of: photoItem) { _, item in loadPickedPhoto(item) }
    }

    private func notePreview(_ image: Image) -> some View {
        image.resizable().scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BBRadius.control, style: .continuous))
    }

    /// Load the picked item's bytes off the main actor, decode a preview, and hold re-encoded JPEG
    /// data to enqueue on save.
    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            pickedImage = image
            pickedImageData = image.bbUploadJPEG() ?? data
        }
    }

    // MARK: Load / save

    private func populate() {
        // A new pumping on a server with the milk stash starts on the child's parent, going into
        // the stash as the server's default says, and a breast-milk bottle taken from it as the
        // server would take it. An edit loads its own below.
        parentID = Self.initialParentID(kind: kind, forChild: childID, in: parents)
        let summary = StashCapability.summary
        toStash = summary?.defaults.pumping_to_stash ?? true
        fromStash = Self.bottleFromStashDefault(defaultOn: summary?.defaults.bottle_from_stash ?? false,
                                                summary: summary, hasStashActivity: cachedStashActivity)
        if entity == nil, let preset = stashPreset {
            stashKind = preset.kind
            if let a = preset.amount { amount = trimmed(a) }
            stashReason = preset.reason
        }
        if let timer = sourceTimer, entity == nil {
            // Converting: inherit the timer's start, end the activity when Stop was tapped.
            if let s = timer.payloadObject["start"] as? String, let d = APIDate.parse(s) { start = d }
            end = timer.stoppedAt ?? Date()
            return
        }
        // A template (the dose a reminder was about) fills the form like an edit, but stays a new
        // record timed now: `buildPayload` only carries `entity`'s id.
        if let c = entity?.payloadObject["child"] as? Int { selectedChildID = c }
        guard let p = (entity ?? template)?.payloadObject else { return }
        defer { if entity == nil { time = Date() } }
        func parseDate(_ key: String) -> Date? { (p[key] as? String).flatMap(APIDate.parse) }
        start = parseDate("start") ?? start
        end = parseDate("end") ?? end
        time = parseDate("time") ?? time
        date = parseDate("date") ?? date
        notes = p["notes"] as? String ?? ""
        tagNames = (p["tags"] as? [String]) ?? []
        if let t = p["type"] as? String, let ft = FeedingType(rawValue: t) { feedingType = ft }
        if let m = p["method"] as? String, let fm = FeedingMethod(rawValue: m) { feedingMethod = fm }
        if let a = p["amount"] as? Double { amount = trimmed(a) }
        if entity != nil, kind == .pumping || kind == .feeding {
            let stashed = p["stash_amount"] as? Double
            if let stashed { storedAmount = trimmed(stashed) }
            if kind == .pumping {
                if let parent = p["parent"] as? Int { parentID = parent }
                toStash = stashed != nil
            } else {
                parentID = p["parent"] as? Int
                fromStash = stashed != nil
                if let discarded = p["stash_discarded"] as? Double, discarded > 0 {
                    discardsSome = true
                    discardedAmount = trimmed(discarded)
                }
                discardReason = p["stash_discard_reason"] as? String ?? ""
            }
        }
        if entity != nil, kind == .stashAdjustment {
            if let k = (p["kind"] as? String).flatMap(StashKind.init(rawValue:)) { stashKind = k }
            stashReason = p["reason"] as? String ?? ""
            parentID = p["parent"] as? Int
        }
        wet = p["wet"] as? Bool ?? wet
        solid = p["solid"] as? Bool ?? solid
        if let c = p["color"] as? String { color = DiaperColor(rawValue: c) }
        nap = p["nap"] as? Bool ?? nap
        milestone = p["milestone"] as? String ?? ""
        noteText = p["note"] as? String ?? ""
        imageURL = (p["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        medName = p["name"] as? String ?? ""
        if let d = p["dosage"] as? Double { dosage = trimmed(d) }
        dosageUnit = p["dosage_unit"] as? String ?? dosageUnit
        if let raw = p["next_dose_interval"] as? String, let seconds = APIDuration.parse(raw), seconds > 0 {
            if MedicationReminderPolicy.choices.contains(seconds) {
                doseInterval = .preset(seconds)
            } else {
                doseInterval = .custom
                customDoseHours = String(Int(seconds) / 3600)
                customDoseMinutes = String(Int(seconds) % 3600 / 60)
            }
        }
        for key in ["weight", "height", "head_circumference", "bmi", "temperature"] {
            if let v = p[key] as? Double { value = trimmed(v) }
        }
        // A reading logged on a phone in the other unit opens in this one, as it's shown everywhere.
        if let t = p["temperature"] as? Double, unit.unit(ofStored: t) != unit { value = trimmed(unit.reading(t)) }
    }

    private func save() {
        let payload = buildPayload()
        let repo = LocalRepository(context: context)
        let target: LocalEntity?
        if let sourceTimer {
            target = repo.convertTimer(sourceTimer, to: kind, payload: payload)
            // Full timer-stop coverage: feeding/pumping (and any editor-based convert) finish
            // here rather than via the dashboard's one-tap path.
            let activity = TimerActivity(convertKind: kind)?.rawValue ?? "other"
            Analytics.timerStopped(activity: activity, source: .app)
        } else if let entity {
            repo.update(entity, payload: payload)
            target = entity
        } else {
            target = repo.create(kind: kind, payload: payload, source: source)
        }
        if let pickedImageData, let target {
            repo.enqueueImageUpload(for: target, imageData: pickedImageData)
        }
        Task { await sync.sync() }
        // Converting a source timer ends the Live Activity for that timer; a plain log is a no-op.
        Task { await liveActivity.reconcile() }
        dismiss()
    }

    /// Begin timing this activity instead of logging a finished record. Creates an open-ended
    /// Baby Buddy timer through the same ``LocalRepository/create`` path the Start Timer sheet
    /// uses; the timer is named after the activity so the convert/widget flow recognizes it.
    private func startTimer(_ activity: TimerActivity) {
        let payload: [String: Any] = [
            "child": childID,
            "start": APIDate.isoDateTime.string(from: start),
            "name": activity.timerName,
        ]
        LocalRepository(context: context).create(kind: .timer, payload: payload)
        Analytics.timerStarted(activity: activity.rawValue, source: .app)
        Task { await sync.sync() }
        Task { await liveActivity.reconcile() } // start the Live Activity for the new timer
        dismiss()
    }

    private func delete() {
        guard let entity else { return }
        LocalRepository(context: context).delete(entity)
        Task { await sync.sync() }
        // Deleting a running timer ends its Live Activity; harmless for other kinds.
        Task { await liveActivity.reconcile() }
        dismiss()
    }

    private func buildPayload() -> [String: Any] {
        var p: [String: Any] = ["child": selectedChildID]
        let tagList = tagNames
        func iso(_ d: Date) -> String { APIDate.isoDateTime.string(from: d) }

        switch kind {
        case .feeding:
            p["start"] = iso(start); p["end"] = iso(end)
            p["type"] = feedingType.rawValue; p["method"] = feedingMethod.rawValue
            if let a = ActivityDraft.number(amount) { p["amount"] = a }
            p["notes"] = notes; p["tags"] = tagList
            let capable = StashCapability.isSupported
            p.merge(Self.feedingStashFields(type: feedingType, method: feedingMethod, fromStash: fromStash,
                                            amount: ActivityDraft.number(amount),
                                            stashAmount: ActivityDraft.number(storedAmount),
                                            discarded: discardsSome ? ActivityDraft.number(discardedAmount) : nil,
                                            discardReason: discardReason, capable: capable)) { $1 }
            p.merge(Self.feedingParentField(method: feedingMethod, parentID: breastfeedingParentID,
                                            linkedParentCount: linkedParentChoices.count,
                                            isNew: entity == nil, capable: capable)) { $1 }
        case .change:
            p["time"] = iso(time); p["wet"] = wet; p["solid"] = solid
            if let color { p["color"] = color.rawValue }
            p["notes"] = notes; p["tags"] = tagList
        case .sleep:
            p["start"] = iso(start); p["end"] = iso(end); p["nap"] = nap
            p["notes"] = notes; p["tags"] = tagList
        case .tummyTime:
            p["start"] = iso(start); p["end"] = iso(end)
            p["milestone"] = milestone; p["tags"] = tagList
        case .pumping:
            p["start"] = iso(start); p["end"] = iso(end)
            if let a = ActivityDraft.number(amount) { p["amount"] = a }
            p["notes"] = notes; p["tags"] = tagList
            p = Self.pumpingPayload(base: p, parentID: parentID, toStash: toStash,
                                    storedAmount: ActivityDraft.number(storedAmount),
                                    amount: ActivityDraft.number(amount), capable: StashCapability.isSupported)
        case .note:
            p["time"] = iso(time); p["note"] = noteText; p["tags"] = tagList
        case .weight, .height, .headCircumference, .bmi:
            let key = ["weight": "weight", "height": "height",
                       "headCircumference": "head_circumference", "bmi": "bmi"][kind.rawValue]!
            p[key] = ActivityDraft.number(value) ?? 0
            p["date"] = APIDate.dateOnly.string(from: date)
            p["notes"] = notes; p["tags"] = tagList
        case .temperature:
            p["temperature"] = ActivityDraft.number(value) ?? 0; p["time"] = iso(time)
            p["notes"] = notes; p["tags"] = tagList
        case .medication:
            p["name"] = medName; p["time"] = iso(time)
            if let d = ActivityDraft.number(dosage) { p["dosage"] = d }
            p["dosage_unit"] = dosageUnit
            p["next_dose_interval"] = doseIntervalSeconds.map(APIDuration.string(from:)) ?? NSNull()
            p["notes"] = notes; p["tags"] = tagList
        case .stashAdjustment:
            p = Self.stashEntryPayload(kind: stashKind, amount: ActivityDraft.number(amount), time: iso(time),
                                       reason: stashReason, parentID: parentID,
                                       parentCount: parentChoices.count, isNew: entity == nil,
                                       notes: notes, tags: tagList)
        case .timer, .child, .parent:
            break
        }
        // Preserve the server id when editing so the payload round-trips.
        if let id = entity?.serverID { p["id"] = id }
        return p
    }

    /// A pumping's payload. On a server with the milk stash (`capable`) it's logged on a parent:
    /// `parent`, and no `child` (the server keeps pumping on a parent at `child: null`), with
    /// `stash_amount` the stored amount, else the whole amount, or null when it was kept out of the
    /// stash or there's no amount above zero to store (the server refuses a stash amount of 0).
    /// Otherwise `base` unchanged: upstream's payload, on the child, with no stash keys.
    /// Creating, editing and converting a timer all go through this.
    static func pumpingPayload(base: [String: Any], parentID: Int?, toStash: Bool, storedAmount: Double?,
                               amount: Double?, capable: Bool) -> [String: Any] {
        guard capable else { return base }
        var p = base
        p.removeValue(forKey: "child")
        if let parentID { p["parent"] = parentID }
        let stashed = toStash && (amount ?? 0) > 0 ? (storedAmount ?? amount) : nil
        p["stash_amount"] = stashed.map { $0 as Any } ?? NSNull()
        return p
    }

    /// The parent a new pumping starts on: the only one linked to `child`. With none or several
    /// it's nil, so the picker starts empty and Save waits for a choice.
    static func defaultParentID(forChild child: Int, in entities: [LocalEntity]) -> Int? {
        let linked = EntityVisibility.parentIDs(forChild: child, in: entities)
        return linked.count == 1 ? linked.first : nil
    }

    /// The parent a new entry starts on: ``defaultParentID(forChild:in:)``, except that a new stash
    /// entry starts on none, as on the web. Its picker only shows with several parents, where one has
    /// to be picked; with one, the server fills it in.
    static func initialParentID(kind: EntityKind, forChild child: Int, in entities: [LocalEntity]) -> Int? {
        kind == .stashAdjustment ? nil : defaultParentID(forChild: child, in: entities)
    }

    /// Whether a new breast-milk bottle starts "Taken from stash". The server applies its default
    /// (`defaultOn`) only once the stash has been used: a pumping put into it, or a stash entry. The
    /// app asks the same of what it has: a cached summary holding milk (or below zero), or
    /// `hasStashActivity`, a cached stash entry or stored pumping, looked up only when needed.
    static func bottleFromStashDefault(defaultOn: Bool, summary: StashSummaryDTO?,
                                       hasStashActivity: @autoclosure () -> Bool) -> Bool {
        guard defaultOn else { return false }
        if let summary, !summary.lots.isEmpty || summary.balance != 0 { return true }
        return hasStashActivity()
    }

    /// Whether the cache shows the stash in use: any stash entry, or a pumping put into the stash.
    private var cachedStashActivity: Bool {
        let adjustment = EntityKind.stashAdjustment.rawValue, pumping = EntityKind.pumping.rawValue
        var entries = FetchDescriptor<LocalEntity>(predicate: #Predicate { entity in
            entity.kindRaw == adjustment
        })
        entries.fetchLimit = 1
        if let found = try? context.fetch(entries), !found.isEmpty { return true }
        let pumpings = (try? context.fetch(FetchDescriptor<LocalEntity>(predicate: #Predicate { entity in
            entity.kindRaw == pumping
        }))) ?? []
        return pumpings.contains { ($0.payloadObject["stash_amount"] as? Double) != nil }
    }

    /// The methods that are a breastfeed, the only ones the server keeps a feeding's `parent` on.
    private static let breastMethods: Set<FeedingMethod> = [.leftBreast, .rightBreast, .bothBreasts]

    /// A feeding that can come from the milk stash: breast milk, fortified or not, from a bottle.
    private static func isStashBottle(type: FeedingType, method: FeedingMethod) -> Bool {
        (type == .breastMilk || type == .fortifiedBreastMilk) && method == .bottle
    }

    /// A feeding's milk stash fields. Nothing without the milk stash (`capable`). A breast-milk bottle
    /// taken from the stash sends `stash_amount` (the amount from the stash, else the whole amount)
    /// and, when some was discarded, `stash_discarded` with its reason, trimmed and cut to the
    /// server's 255 characters. Anything else sends the three cleared, so an edit that stops a bottle
    /// coming from the stash (or discarding some) removes it on the server. The discard and its
    /// reason always go together, and a discard never goes without a `stash_amount`: the server
    /// refuses either.
    static func feedingStashFields(type: FeedingType, method: FeedingMethod, fromStash: Bool, amount: Double?,
                                   stashAmount: Double?, discarded: Double?, discardReason: String?,
                                   capable: Bool) -> [String: Any] {
        guard capable else { return [:] }
        let taken: Double? = fromStash && isStashBottle(type: type, method: method) ? (stashAmount ?? amount) : nil
        guard let taken else {
            return ["stash_amount": NSNull(), "stash_discarded": NSNull(), "stash_discard_reason": ""]
        }
        guard let discarded, discarded > 0 else {
            return ["stash_amount": taken, "stash_discarded": NSNull(), "stash_discard_reason": ""]
        }
        return ["stash_amount": taken, "stash_discarded": discarded,
                "stash_discard_reason": cappedReason(discardReason ?? "")]
    }

    /// A stash reason as the server takes it: trimmed, and at most 255 characters, counted as code
    /// points the way the server counts them.
    static func cappedReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(255)))
    }

    /// A stash entry's payload: kind, amount, time, reason, notes and tags, and never a `child` (the
    /// stash belongs to the parents) nor the server's computed `signed_amount` or bottle link.
    /// `parent` only when there are several parents (`parentCount`) to tell apart: the pick, else
    /// nothing on a new entry and a cleared parent on an edit. With one parent or none the key is
    /// left out, so the server fills in the only parent on a new entry and keeps an edit's own.
    static func stashEntryPayload(kind: StashKind, amount: Double?, time: String, reason: String,
                                  parentID: Int?, parentCount: Int, isNew: Bool,
                                  notes: String, tags: [String]) -> [String: Any] {
        var p: [String: Any] = ["time": time, "kind": kind.rawValue, "reason": cappedReason(reason),
                                "notes": notes, "tags": tags]
        if let amount { p["amount"] = amount }
        if parentCount >= 2 {
            if let parentID {
                p["parent"] = parentID
            } else if !isNew {
                p["parent"] = NSNull()
            }
        }
        return p
    }

    /// Who breastfed, on a server with the milk stash (`capable`), for a breastfeed only: the server
    /// drops a parent on other methods. The chosen parent, else nothing on a new feeding (the server
    /// fills in the child's only parent), else a cleared parent when the child has several to
    /// choose from.
    static func feedingParentField(method: FeedingMethod, parentID: Int?, linkedParentCount: Int, isNew: Bool,
                                   capable: Bool) -> [String: Any] {
        guard capable, breastMethods.contains(method) else { return [:] }
        if let parentID { return ["parent": parentID] }
        if !isNew, linkedParentCount >= 2 { return ["parent": NSNull()] }
        return [:]
    }

    /// Who breastfed. An edit keeps the picker's value. A new feeding takes the child's only parent
    /// when the picker is hidden, and otherwise the pick when it's one of the child's parents, never
    /// one chosen for a pumping before switching kinds.
    private var breastfeedingParentID: Int? {
        if isEditing { return parentID }
        let linked = linkedParentChoices.map { $0.id }
        if linked.count < 2 { return linked.first }
        guard let parentID, linked.contains(parentID) else { return nil }
        return parentID
    }

    /// The chosen next-dose interval in seconds; a blank or zero custom entry means none.
    private var doseIntervalSeconds: TimeInterval? {
        switch doseInterval {
        case .none: return nil
        case .preset(let seconds): return seconds
        case .custom:
            let seconds = (ActivityDraft.number(customDoseHours) ?? 0) * 3600
                + (ActivityDraft.number(customDoseMinutes) ?? 0) * 60
            return seconds > 0 ? seconds : nil
        }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A medication's next-dose interval as the editor offers it: none, a preset, or typed in.
private enum DoseInterval: Hashable {
    case none, preset(TimeInterval), custom

    var label: String {
        switch self {
        case .none: return "None"
        case .preset(let seconds): return EntityFormatting.formatInterval(seconds)
        case .custom: return "Custom"
        }
    }
}

/// Compact, presentation-only labels for the feeding-type segmented control (the model's
/// full `label` — e.g. "Fortified Breast Milk" — is too long for four segments).
private extension FeedingType {
    var shortLabel: String {
        switch self {
        case .breastMilk: return "Breast"
        case .formula: return "Formula"
        case .fortifiedBreastMilk: return "Fortified"
        case .solidFood: return "Solid"
        }
    }
}
