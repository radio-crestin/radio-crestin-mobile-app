import SwiftUI

/// The app's standard focusable text button for tvOS.
///
/// Replaces bare `Button("…").buttonStyle(.card)`. The system `.card`
/// style sizes its card to the label with almost no inset, so a plain
/// `Text` ends up touching the pill edges — the overflow the user
/// reported on the playlist skip-card and the stream-error screen. Owning
/// the chrome here means the padding is defined in exactly one place and
/// every screen picks up the fix.
///
/// Metrics follow the tvOS HIG: a generous focus target (>= 64pt tall),
/// symmetric horizontal inset roughly 1.5x the vertical one, and a focus
/// state that scales and glows rather than only changing color, so the
/// focused control is unmistakable from 10 feet away.
struct TVPillButton: View {
    let title: String
    var systemImage: String?

    /// Brand-filled treatment for the primary action in a row (e.g.
    /// "Reîncearcă" next to a secondary "Înapoi la posturi").
    var isProminent: Bool = false

    let action: () -> Void

    @FocusState private var isFocused: Bool

    /// Horizontal inset. Wide enough that descenders and diacritics in
    /// long Romanian labels never crowd the capsule's curve.
    private static let hInset: CGFloat = 36
    private static let vInset: CGFloat = 20
    private static let minHeight: CGFloat = 64

    /// Gap between sibling pills in a row. Two adjacent capsules need
    /// real separation or the focus halo of one reads as part of the
    /// other.
    static let rowSpacing: CGFloat = 32

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .heavy))
                }
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    // Long labels shrink a little before they ever clip.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Self.hInset)
            .padding(.vertical, Self.vInset)
            .frame(minHeight: Self.minHeight)
            .background(
                Capsule().fill(
                    isFocused
                        ? Theme.primary
                        : (isProminent
                            ? Theme.primary.opacity(0.85)
                            : Color.white.opacity(0.12))
                )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.25),
                    lineWidth: isFocused ? 4 : 1.5
                )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: isFocused
                    ? Theme.primary.opacity(0.7)
                    : .black.opacity(0.45),
                radius: isFocused ? 28 : 10, x: 0, y: 8
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: isFocused)
        }
        // `.plain` so tvOS doesn't draw its rounded-rectangle card halo
        // around what is visually a capsule.
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}
