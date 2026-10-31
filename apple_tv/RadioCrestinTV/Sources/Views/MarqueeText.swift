import SwiftUI
import UIKit

/// One line of a card's caption: cut at the end, and scrolled on the
/// focused card when it does not fit, as tvOS scrolls a cut label in
/// Apple's apps.
///
/// tvOS does this itself for a `UILabel`
/// (`enablesMarqueeWhenAncestorFocused`), but not inside a SwiftUI button:
/// SwiftUI's focus never reaches the label's UIKit ancestors, so the line
/// stood still on the focused card (tried on the tvOS 27 simulator). This
/// line moves as the system's does (see `MarqueeLoop`), for as long as the
/// card keeps focus.
///
/// A card without focus, or a line that fits, is a plain `Text`: nothing
/// is measured and nothing runs, so only the focused card does any work.
/// There the moving line is a Core Animation animation (see
/// `MarqueeLineView`), which the app does no work for while it runs.
struct MarqueeText: View {
    let text: String
    let font: UIFont
    let color: Color
    /// The card has focus: the line may scroll.
    let isActive: Bool
    /// How much larger the focused card draws the line (its `.card`
    /// lift), so the line moves, rests and fades at the system's sizes on
    /// screen.
    var focusScale: CGFloat = 1

    /// The line is wider than the card. Measured only while active.
    @State private var overflows = false

    var body: some View {
        Text(text)
            .font(Font(font))
            // Clear while the moving copy shows the line. Not hidden: at
            // opacity 0 the card's VoiceOver label lost the line, and an
            // `accessibilityRepresentation` kept it at 5 MB more memory.
            .foregroundStyle(isActive && overflows ? .clear : color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isActive {
                    MarqueeFit(text: text, font: font, overflows: $overflows)
                    if overflows {
                        MarqueeLine(content: MarqueeLineView.Content(
                            text: text,
                            font: font,
                            color: UIColor(color),
                            scale: focusScale
                        ))
                        .accessibilityHidden(true)
                    }
                }
            }
    }
}

/// How the marquee moves, copied from the system's on the tvOS 27
/// simulator (a recording of a `UILabel` marquee at 60 fps): 2 s after the
/// card takes focus, the line moves left at a steady 45 pt/s, followed
/// 40 pt behind by a copy of itself, until the copy stands where the line
/// started; it rests there 3 s and goes again. An 8 pt fade softens the
/// cut at the trailing edge and, while the line is away from its start,
/// the leading edge too.
///
/// The sizes are on screen; a pass is laid out in the line's own points,
/// which a focused card draws `scale` times larger.
struct MarqueeLoop {
    /// Seconds from focus to the first pass.
    static let firstRest: CFTimeInterval = 2
    /// Seconds at the start between passes.
    static let rest: CFTimeInterval = 3
    /// Seconds the leading fade takes to come or go.
    static let fadeDuration: CFTimeInterval = 0.15
    /// Points per second.
    static let speed: CGFloat = 45
    /// Between the end of the line and the copy that follows it.
    static let gap: CGFloat = 40
    static let fadeWidth: CGFloat = 8

    /// The copy's distance behind the line's start, in the line's points.
    let travel: CGFloat
    /// The fades' width in the line's points.
    let fadeWidth: CGFloat
    /// Seconds one pass takes.
    let duration: CFTimeInterval
    /// Seconds into a pass when the leading fade starts to go. The copy is
    /// then half the gap from the start, so the fade leaves while only the
    /// empty gap passes under it, and the copy's first letter arrives
    /// sharp, as it rests.
    let leadingFadeEnd: CFTimeInterval

    init(lineWidth: CGFloat, scale: CGFloat = 1) {
        let speed = Self.speed / scale
        let gap = Self.gap / scale
        travel = lineWidth + gap
        fadeWidth = Self.fadeWidth / scale
        duration = CFTimeInterval(travel / speed)
        leadingFadeEnd = CFTimeInterval((travel - gap / 2) / speed)
    }

    /// Seconds from the start of one pass to the next.
    var period: CFTimeInterval { duration + Self.rest }

    /// Whether a line `line` points wide is cut in a box `box` points
    /// wide. An unmeasured box (0) cuts nothing; half a point of slack
    /// absorbs the rounding of measured sizes.
    static func overflows(line: CGFloat, box: CGFloat) -> Bool {
        box > 0 && line > box + 0.5
    }
}

/// Measures, on the focused card only, whether the line is wider than the
/// card.
private struct MarqueeFit: View {
    let text: String
    let font: UIFont
    @Binding var overflows: Bool

    @State private var lineWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                boxWidth = $0
            }
            .background(alignment: .leading) {
                // The width the whole line needs.
                Text(text)
                    .font(Font(font))
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        lineWidth = $0
                    }
            }
            .onChange(
                of: MarqueeLoop.overflows(line: lineWidth, box: boxWidth)
            ) { _, value in
                overflows = value
            }
            .onDisappear { overflows = false }
    }
}

/// The moving line, in the box of the `Text` it covers.
private struct MarqueeLine: UIViewRepresentable {
    let content: MarqueeLineView.Content

    func makeUIView(context: Context) -> MarqueeLineView {
        MarqueeLineView()
    }

    func updateUIView(_ view: MarqueeLineView, context: Context) {
        view.show(content)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarqueeLineView,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// A cut line followed by its copy, moved by Core Animation as
/// `MarqueeLoop` describes.
///
/// Moved by SwiftUI, the same line cost the app 7–8 % CPU on the simulator
/// for as long as it scrolled: every frame re-resolved the `.card`
/// button's focus effects around it. Core Animation runs the animation in
/// the render server, as it runs the system's marquee, so the app does no
/// work while the line moves. A new line or a new width starts over from
/// rest.
final class MarqueeLineView: UIView {
    struct Content: Equatable {
        let text: String
        let font: UIFont
        let color: UIColor
        let scale: CGFloat
    }

    private let track = UIView()
    private let line = UILabel()
    private let copy = UILabel()
    /// The mask: opaque, with soft ends.
    private let edges = CAGradientLayer()

    private var content: Content?
    /// The size the running animation was laid out for.
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // VoiceOver reads the line from the `Text` underneath.
        accessibilityElementsHidden = true
        for label in [line, copy] {
            label.numberOfLines = 1
            label.lineBreakMode = .byClipping
            label.isAccessibilityElement = false
            track.addSubview(label)
        }
        addSubview(track)
        edges.startPoint = CGPoint(x: 0, y: 0.5)
        edges.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = edges
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        for label in [line, copy] {
            label.text = content.text
            label.font = content.font
            label.textColor = content.color
        }
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content,
              bounds.width > 0,
              bounds.size != laidOutSize
        else { return }
        laidOutSize = bounds.size
        let lineWidth = ceil(line.intrinsicContentSize.width)
        run(
            MarqueeLoop(lineWidth: lineWidth, scale: content.scale),
            lineWidth: lineWidth
        )
    }

    private func run(_ loop: MarqueeLoop, lineWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        line.frame = CGRect(x: 0, y: 0, width: lineWidth, height: height)
        copy.frame = line.frame.offsetBy(dx: loop.travel, dy: 0)
        track.frame = CGRect(x: 0, y: 0, width: copy.frame.maxX, height: height)
        // Taller than the line, so no accent or descender is cut.
        edges.frame = bounds.insetBy(dx: 0, dy: -height / 2)
        let fade = min(loop.fadeWidth / bounds.width, 0.5)
        edges.locations = [0, fade, 1 - fade, 1].map { NSNumber(value: $0) }
        edges.colors = Self.sharpStart
        track.layer.removeAllAnimations()
        edges.removeAllAnimations()
        let start = CACurrentMediaTime() + MarqueeLoop.firstRest
        track.layer.add(Self.motion(loop, from: start), forKey: "marquee")
        edges.add(Self.leadingFade(loop, from: start), forKey: "marquee")
        CATransaction.commit()
    }

    // MARK: - Animations

    private static let opaque = UIColor.black.cgColor
    private static let clear = UIColor.clear.cgColor
    /// The mask at rest: a fade at the trailing end only.
    private static let sharpStart = [opaque, opaque, opaque, clear]
    /// The mask while the line moves: a fade at both ends.
    private static let softStart = [clear, opaque, opaque, clear]

    /// Each pass, the line and its copy move one `travel` left, then rest.
    private static func motion(
        _ loop: MarqueeLoop,
        from start: CFTimeInterval
    ) -> CAAnimation {
        let motion = CAKeyframeAnimation(keyPath: "transform.translation.x")
        motion.values = [0, -loop.travel, -loop.travel]
        motion.keyTimes = keyTimes([0, loop.duration, loop.period], of: loop)
        return repeating(motion, loop, from: start)
    }

    /// Each pass, the leading fade comes as the line leaves its start and
    /// goes before the copy arrives there.
    private static func leadingFade(
        _ loop: MarqueeLoop,
        from start: CFTimeInterval
    ) -> CAAnimation {
        let fade = MarqueeLoop.fadeDuration
        let fades = CAKeyframeAnimation(keyPath: "colors")
        fades.values = [
            sharpStart, softStart, softStart, sharpStart, sharpStart,
        ]
        fades.keyTimes = keyTimes([
            0, fade, loop.leadingFadeEnd, loop.leadingFadeEnd + fade,
            loop.period,
        ], of: loop)
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let linear = CAMediaTimingFunction(name: .linear)
        fades.timingFunctions = [ease, linear, ease, linear]
        return repeating(fades, loop, from: start)
    }

    private static func keyTimes(
        _ seconds: [CFTimeInterval],
        of loop: MarqueeLoop
    ) -> [NSNumber] {
        seconds.map { NSNumber(value: $0 / loop.period) }
    }

    /// One pass per period, forever, from `start`; before it, the first
    /// frame (the line at rest).
    private static func repeating(
        _ animation: CAKeyframeAnimation,
        _ loop: MarqueeLoop,
        from start: CFTimeInterval
    ) -> CAAnimation {
        animation.duration = loop.period
        animation.beginTime = start
        animation.repeatCount = .infinity
        animation.fillMode = .backwards
        // Kept when the app goes to the background and comes back.
        animation.isRemovedOnCompletion = false
        return animation
    }
}
