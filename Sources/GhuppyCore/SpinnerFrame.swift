import Foundation

/// One moment of the triangle spinner, on a circle of radius 1 around the
/// origin.
///
/// One dot crosses the circle in a straight line through the centre while the
/// other two slide along it the opposite way, and the three meet as an
/// equilateral triangle as the crossing ends. The next crossing starts at
/// once, so no dot ever stops: the dot that just arrived carries on along the
/// circle, and another sets off across, each dot taking its turn. Or, when
/// `circling`, one dot never crosses but keeps sliding round the circle while
/// the other two take turns.
public struct SpinnerFrame: Sendable {
    /// How long one crossing takes, in seconds.
    public static let crossingDuration = 0.5

    /// How far the lines bend at the end of each crossing, in turn. Each line
    /// runs through its midpoint scaled by `1 - curve / 2`, so at 2 the lines
    /// meet in the centre, at 0 they are straight, and at -2 they make up the
    /// whole circle.
    private static let deepestCurves = [1.2, -1.2]

    /// The dots at rest, joined by straight lines.
    public static let triangle = SpinnerFrame(at: 0, curveScale: 0)

    /// The crossing dot, then the two dots on the circle. When `circling`, the
    /// last is always the dot that never crosses.
    public let dots: [SIMD2<Double>]

    /// How far the lines bend right now, on the scale of `deepestCurves`.
    public let curve: Double

    /// The lines joining the dots, as a closed run of points.
    public let outline: [SIMD2<Double>]

    /// The frame at `time` seconds, which must not be negative, with the
    /// lines bent by `curveScale` of their usual amount: 0 straightens them,
    /// for easing in and out of the still triangle. The whole frame is turned
    /// by `rotation` radians, and each line drawn with `pointsPerLine` points.
    ///
    /// When `circling`, each crossing starts a sixth of a turn further on than
    /// the last, so the dot sliding forwards round the circle is always the
    /// same one, and the other two take turns crossing. It is back where it
    /// started after six crossings; otherwise every two.
    public init(
        at time: TimeInterval,
        curveScale: Double = 1,
        rotation: Double = 0,
        pointsPerLine: Int = 12,
        circling: Bool = false
    ) {
        let crossings = time / Self.crossingDuration
        let crossing = crossings.rounded(.down)
        let progress = crossings - crossing
        let index = Int(crossing.truncatingRemainder(dividingBy: 2))
        let turn = circling ? Int(crossing.truncatingRemainder(dividingBy: 6)) : index

        let start = Double(turn * 60 - 75) * .pi / 180 + rotation
        let spread = (120 - 60 * progress) * .pi / 180
        // Keeps the centre of the triangle on the centre of the circle.
        let distance = -2 * cos(spread)
        let dots = [
            distance * Self.direction(start),
            Self.direction(start + spread),
            Self.direction(start - spread),
        ]

        // The lines go straight as the dot passes the centre, which is where
        // one setting hands over to the other without a jump.
        let bend = cos(.pi * progress)
        let curve = Self.deepestCurves[(progress < 0.5 ? index : index + 1) % 2] * bend * bend * curveScale

        self.dots = dots
        self.curve = curve
        outline = dots.indices.flatMap { side in
            let start = dots[side], end = dots[(side + 1) % dots.count]
            return Self.arc(from: start, to: end, through: (start + end) / 2 * (1 - curve / 2), points: pointsPerLine)
        }
    }

    private static func direction(_ angle: Double) -> SIMD2<Double> {
        SIMD2(cos(angle), sin(angle))
    }

    /// `points` points along the circular arc through three points, leaving
    /// out `end`, where the next line starts.
    private static func arc(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        through middle: SIMD2<Double>,
        points: Int
    ) -> [SIMD2<Double>] {
        let chord = end - start, offset = middle - start
        let twiceArea = 2 * (chord.x * offset.y - chord.y * offset.x)
        let steps = (0..<points).map { Double($0) / Double(points) }
        guard abs(twiceArea) > 1e-6 else {
            return steps.map { start + chord * $0 }
        }

        let chordSquared = (chord * chord).sum(), offsetSquared = (offset * offset).sum()
        let centre = start + SIMD2(
            offset.y * chordSquared - chord.y * offsetSquared,
            chord.x * offsetSquared - offset.x * chordSquared
        ) / twiceArea
        let radius = start - centre
        let length = (radius * radius).sum().squareRoot()

        func angle(of point: SIMD2<Double>) -> Double {
            atan2(point.y - centre.y, point.x - centre.x)
        }
        func turn(to point: SIMD2<Double>) -> Double {
            let turn = (angle(of: point) - angle(of: start)).truncatingRemainder(dividingBy: 2 * .pi)
            return turn < 0 ? turn + 2 * .pi : turn
        }
        let sweep = turn(to: middle) <= turn(to: end) ? turn(to: end) : turn(to: end) - 2 * .pi
        return steps.map { centre + length * direction(angle(of: start) + sweep * $0) }
    }
}
