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
            // As large as the stars, in the secondary colour: two points
            // smaller and half white, it measured 3.3:1 over the backdrop
            // of a white logo.
            if showCount && count > 0 {
                Text("(\(count))")
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        // One element for VoiceOver, in Romanian: the stars alone read as
        // five English "Favorite" images.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// "Evaluare 4,8 din 5, 215 recenzii".
    var accessibilityDescription: String {
        let average = rating.formatted(
            .number.precision(.fractionLength(0...1))
                .locale(Locale(identifier: "ro"))
        )
        let rated = "Evaluare \(average) din 5"
        guard count > 0 else { return rated }
        let reviews = RomanianCount.phrase(
            count, one: "recenzie", many: "recenzii"
        )
        return "\(rated), \(reviews)"
    }

    private func symbolName(for index: Int) -> String {
        let position = Double(index) + 0.5
        if rating >= position + 0.5 { return "star.fill" }
        if rating >= position { return "star.leadinghalf.filled" }
        return "star"
    }
}
