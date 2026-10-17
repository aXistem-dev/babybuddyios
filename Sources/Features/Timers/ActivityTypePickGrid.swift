import SwiftUI

/// The Start and Stop Timer sheets' "Activities" grid: a tile per activity type, picked instead of
/// one of the kinds above it. Tapping the picked type again unpicks it. Nothing shows without types.
struct ActivityTypePickGrid: View {
    let types: [ActivitiesCapability.TypeInfo]
    @Binding var selection: Int?
    /// Called when a type is tapped, so the sheet can clear the kind it had picked.
    var onPick: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        if !types.isEmpty {
            SectionHeader("Activities")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(types) { type in
                    ActivityPickTile(kind: .activity, title: type.name, icon: type.tileIcon,
                                     isSelected: selection == type.id) {
                        selection = (selection == type.id) ? nil : type.id
                        onPick()
                    }
                }
            }
        }
    }
}
