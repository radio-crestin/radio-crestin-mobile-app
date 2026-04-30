import SwiftUI

/// Sort selector shown in the trailing slot of `StationGrid`'s header.
///
/// Implemented as a `Button` + `confirmationDialog` rather than `Menu`
/// because tvOS's `Menu` (with any non-default `menuStyle`) drops the
/// system focus halo, leaving the picker visually flat compared to the
/// rest of the focusable controls. A confirmationDialog presents a
/// native action sheet — same UX as Apple Music / TV+ sort affordances —
/// and the trigger button gets `.buttonStyle(.card)` so it focuses
/// consistently with the station cards next to it.
struct SortPicker: View {
    @Binding var selection: StationSort
    @State private var isPresenting = false

    var body: some View {
        Button {
            isPresenting = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selection.systemIcon)
                Text(selection.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(.card)
        .confirmationDialog(
            "Sortează posturile",
            isPresented: $isPresenting,
            titleVisibility: .visible
        ) {
            ForEach(StationSort.allCases) { option in
                Button(option.label) { selection = option }
            }
            Button("Anulează", role: .cancel) {}
        }
    }
}
