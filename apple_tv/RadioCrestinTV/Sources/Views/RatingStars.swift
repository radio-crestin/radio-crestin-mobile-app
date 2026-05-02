import SwiftUI

/// Compact 5-star rating display. Half-stars rounded to nearest 0.5.
struct RatingStars: View {
    let rating: Double          // 0...5
    let count: Int              // for the "(123)" suffix
    var size: CGFloat = 18
    var showCount: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<5) { i in
                    Image(systemName: symbolName(for: i))
                        .font(.system(size: size))
                        .foregroundStyle(rating > 0 ? .yellow : Theme.textTertiary)
                }
            }
            if showCount && count > 0 {
                Text("(\(count))")
                    .font(.system(size: size - 2))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func symbolName(for index: Int) -> String {
        let position = Double(index) + 0.5
        if rating >= position + 0.5 { return "star.fill" }
        if rating >= position { return "star.leadinghalf.filled" }
        return "star"
    }
}
