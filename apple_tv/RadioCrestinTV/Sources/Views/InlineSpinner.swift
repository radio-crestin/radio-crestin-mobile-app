import SwiftUI

/// Connecting indicator that sits *on* a title line rather than in a
/// message row of its own.
///
/// It is a spinner and nothing else — no "Se conectează…" caption. The
/// state is self-evident from the animation, and a text row next to a
/// station title reads as an error message on a 10-foot screen.
///
/// The view always occupies its slot and only fades its contents, so the
/// title beside it never shifts when connecting starts or ends.
struct InlineSpinner: View {
    var isActive: Bool

    /// Match this to the line height of the text it sits next to.
    var size: CGFloat = 22
    var tint: Color = Theme.textSecondary

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(tint)
            // `controlSize(.small)` renders at a fixed ~22pt on tvOS;
            // scale it to the caller's line height so it reads as part of
            // the text run.
            .scaleEffect(size / 22)
            .frame(width: size, height: size)
            .opacity(isActive ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .accessibilityHidden(!isActive)
            .accessibilityLabel("Se încarcă")
    }
}
