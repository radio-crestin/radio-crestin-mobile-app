import SwiftUI

/// Compact menu that lets the user switch between recommended /
/// most-played / listeners / alphabetical. Lives in the trailing slot
/// of `StationGrid`'s header.
struct SortPicker: View {
    @Binding var selection: StationSort

    var body: some View {
        Menu {
            ForEach(StationSort.allCases) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Image(systemName: option.systemIcon)
                        Text(option.label)
                        if option == selection {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.systemIcon)
                Text(selection.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .menuStyle(.borderlessButton)
        .background(
            Theme.surfaceVariant,
            in: RoundedRectangle(cornerRadius: Theme.Radius.md)
        )
    }
}
