import Foundation

/// One moment of the cleanup spinner, which rests as the Ghuppy logo and
/// runs as the triangle spinner, on the same circle of radius 1 as
/// `SpinnerFrame`. The fish is a little wider than the circle: see `width`.
///
/// It sets off at once from the logo into the first crossing, the lines
/// untangling into the triangle while the eye grows into a dot where it is.
/// When the head of the line reaches the eye, the dot rides the line across
/// to the other side. From the end of the first crossing it is the triangle
/// spinner, circling: the top node slides on round the circle while the other
/// two take turns crossing, the first crossing starting at the fish's head.
/// When told to stop, it runs on to the end of a cycle whose last crossing
/// untangles back into the fish, the dot leaving the line at the eye and
/// shrinking back into it.
public struct FishFrame: Sendable {
    public struct Dot: Sendable, Equatable {
        public let position: SIMD2<Double>
        /// 1 for a full dot, 0 for the size of the logo's eye.
        public let growth: Double
    }

    /// Two crossings: after each the dots sit where the fish's do, and the
    /// fish can come back.
    public static let cycle = 2 * SpinnerFrame.crossingDuration

    /// The logo, at rest.
    public static let fish = FishFrame(at: 0)

    /// The top node, the bottom node, then the eye. Between the first and
    /// last crossings, when they all look alike, which dot stands for which
    /// is decided by the last crossing, so the order can change there.
    public let dots: [Dot]

    /// The lines joining the dots, as a closed run of points.
    public let outline: [SIMD2<Double>]

    /// The frame `time` seconds into a run, which must not be negative. With
    /// `settles`, from `settles(stoppingAt:)`, it comes back to the fish and
    /// stays there from that time.
    public init(at time: TimeInterval, settles: TimeInterval? = nil) {
        let crossing = SpinnerFrame.crossingDuration
        let time = settles.map { min(time, $0) } ?? time
        let frame = SpinnerFrame(at: time, rotation: Self.rotation, pointsPerLine: Self.pointsPerLine, circling: true)

        // How far from the fish towards the spinner, how far the eye has
        // grown into a dot, and how far it has joined the line.
        var morph = smooth(time / crossing), growth = 1.0, joined = 1.0
        var roles = Self.firstRoles
        if time < crossing {
            growth = smooth(time / Self.join)
            joined = smooth((time - Self.join) / Self.glide)
        }
        if let settles, time > settles - crossing {
            let last = Int((settles / crossing).rounded()) - 1
            let leave = Self.leave(after: last)
            let into = time - (settles - crossing)
            roles = Self.lastRoles(last)
            morph = min(morph, smooth((settles - time) / crossing))
            growth = min(growth, smooth((crossing - into) / (crossing - leave)))
            joined = min(joined, smooth((leave - into) / Self.glide))
        }

        var dots = [Role: Dot]()
        var outline = [SIMD2<Double>]()
        for (index, role) in roles.enumerated() {
            let position = mix(role.position, frame.dots[index], morph)
            dots[role] = role == .eye
                ? Dot(position: mix(Self.eye, position, joined), growth: growth)
                : Dot(position: position, growth: 1)
            let side = frame.outline[(index * Self.pointsPerLine)..<((index + 1) * Self.pointsPerLine)]
            let fish = Self.fishLines[Self.Line(from: role, to: roles[(index + 1) % roles.count])]!
            outline += zip(fish, side).map { mix($0, $1, morph) }
        }
        self.dots = [dots[.top]!, dots[.bottom]!, dots[.eye]!]
        self.outline = outline
    }

    /// When a run told to stop `elapsed` seconds in comes back to rest: the
    /// end of a cycle, leaving a whole crossing to untangle in.
    public static func settles(stoppingAt elapsed: TimeInterval) -> TimeInterval {
        max(cycle, ((elapsed + SpinnerFrame.crossingDuration) / cycle).rounded(.up) * cycle)
    }

    /// Whether a run that settles at `settles` has started turning back into
    /// the fish by `elapsed` seconds, so can no longer simply carry on.
    public static func isUntangling(at elapsed: TimeInterval, settles: TimeInterval) -> Bool {
        elapsed > settles - SpinnerFrame.crossingDuration
    }

    // MARK: - The logo

    private enum Role: CaseIterable {
        case eye, top, bottom

        /// Where the dot sits in the fish. The eye's dot is on the line at the
        /// head, where the eye joins it.
        var position: SIMD2<Double> {
            switch self {
            case .eye: FishFrame.head
            case .top: FishFrame.top
            case .bottom: FishFrame.bottom
            }
        }
    }

    /// What each of the spinner's dots stands for in its first crossing: the
    /// crossing dot leaves the head, and the top node is the one that circles.
    private static let firstRoles: [Role] = [.eye, .bottom, .top]

    /// What each of the dots of the last crossing, the `last`th, comes back
    /// as. The crossing dot always comes back to the head. Where the crossing
    /// ends with it on the head, the others go to the nodes they end beside,
    /// which makes the circling dot the bottom node; elsewhere it stays the
    /// top node, which untangles most cleanly.
    private static func lastRoles(_ last: Int) -> [Role] {
        last % 6 == 3 ? [.eye, .top, .bottom] : [.eye, .bottom, .top]
    }

    /// Turns the spinner so its first crossing starts at the fish's head.
    private static let rotation = 75 * Double.pi / 180

    /// Enough to keep the fish's curves smooth at icon sizes.
    private static let pointsPerLine = 32

    /// How long the dot takes to settle onto the line, or off it: the logo's
    /// eye sits just above the line's path.
    private static let glide = 0.06

    // Points from Resources/AppIcon.icon/Assets, in its 1024-point units.
    private static let topPoint = SIMD2(150.0, 233.6), bottomPoint = SIMD2(150.0, 790.4)
    private static let crossingPoint = SIMD2(360.0, 512), headPoint = SIMD2(908.0, 512)

    /// How much wider than the spinner's circle the fish is, so that at rest
    /// it stands as tall as the symbols beside it.
    public static let width = 1.15

    /// The tail nodes at x = -`width` and the head at x = `width`.
    private static func unit(_ point: SIMD2<Double>) -> SIMD2<Double> {
        (point - SIMD2(529, 512)) / 379 * width
    }

    private static let top = unit(topPoint), bottom = unit(bottomPoint), head = unit(headPoint)
    private static let eye = unit(SIMD2(745, 483.2))

    private struct Line: Hashable {
        let from: Role, to: Role
    }

    /// The fish's lines between each two of its dots, either way round.
    private static let fishLines: [Line: [SIMD2<Double>]] = {
        // From the top node it crosses down and round the belly to the head.
        let fromTop = curve([
            [topPoint, SIMD2(230, 317.6), SIMD2(305, 443.6), crossingPoint],
            [crossingPoint, SIMD2(450, 620), SIMD2(560, 692), SIMD2(680, 692)],
            [SIMD2(680, 692), SIMD2(805, 692), SIMD2(908, 610.4), headPoint],
        ])
        // From the head it runs back along the top and crosses down to the bottom node.
        let toBottom = curve([
            [headPoint, SIMD2(908, 413.6), SIMD2(805, 332), SIMD2(680, 332)],
            [SIMD2(680, 332), SIMD2(560, 332), SIMD2(450, 404), crossingPoint],
            [crossingPoint, SIMD2(300, 584), SIMD2(250, 723.2), bottomPoint],
        ])
        var lines = [Line: [SIMD2<Double>]]()
        for (from, to, line) in [(Role.top, Role.eye, fromTop), (.eye, .bottom, toBottom), (.bottom, .top, [bottom, top])] {
            lines[Line(from: from, to: to)] = evenly(line, count: pointsPerLine)
            lines[Line(from: to, to: from)] = evenly(line.reversed(), count: pointsPerLine)
        }
        return lines
    }()

    /// A run of cubic Béziers, finely sampled, in unit coordinates.
    private static func curve(_ segments: [[SIMD2<Double>]]) -> [SIMD2<Double>] {
        let steps = 100
        var points = segments.flatMap { segment in
            (0..<steps).map { step in
                let t = Double(step) / Double(steps), u = 1 - t
                let a = u * u * u * segment[0] + 3 * u * u * t * segment[1]
                return unit(a + 3 * u * t * t * segment[2] + t * t * t * segment[3])
            }
        }
        points.append(unit(segments[segments.count - 1][3]))
        return points
    }

    /// `count` points evenly spaced along a line, leaving out its end, like
    /// the spinner's sides.
    private static func evenly(_ line: [SIMD2<Double>], count: Int) -> [SIMD2<Double>] {
        var lengths = [0.0]
        for index in line.indices.dropFirst() {
            lengths.append(lengths[index - 1] + length(line[index] - line[index - 1]))
        }
        var segment = 1
        return (0..<count).map { step in
            let distance = lengths[lengths.count - 1] * Double(step) / Double(count)
            while lengths[segment] < distance { segment += 1 }
            let span = lengths[segment] - lengths[segment - 1]
            let fraction = span > 0 ? (distance - lengths[segment - 1]) / span : 0
            return mix(line[segment - 1], line[segment], fraction)
        }
    }

    // MARK: - Where the eye meets the line

    /// Where the head of the line is, `time` seconds into the `crossing`th
    /// crossing: on its way across in the first, or back in the last. The
    /// eye's dot is the crossing dot in both.
    private static func headOfLine(at time: TimeInterval, crossing: Int, back: Bool) -> SIMD2<Double> {
        let duration = SpinnerFrame.crossingDuration
        let morph = smooth(back ? (duration - time) / duration : time / duration)
        let frame = SpinnerFrame(
            at: Double(crossing) * duration + time,
            rotation: rotation,
            pointsPerLine: 1,
            circling: true
        )
        return mix(head, frame.dots[0], morph)
    }

    /// When the head of the line passes the eye in the `crossing`th crossing,
    /// on its way across or, when `back`, on its way back.
    private static func passing(crossing: Int, back: Bool) -> TimeInterval {
        let steps = 2000
        let times = (0...steps).map { SpinnerFrame.crossingDuration * Double($0) / Double(steps) }
        let past = times.filter { headOfLine(at: $0, crossing: crossing, back: back).x <= eye.x }
        return (back ? past.last : past.first) ?? SpinnerFrame.crossingDuration / 2
    }

    private static let join = passing(crossing: 0, back: false)

    /// For each way a last crossing can fall in the circling dot's lap: it
    /// is always an odd one, the 1st, 3rd or 5th of six.
    private static let leaves = [1, 3, 5].map { passing(crossing: $0, back: true) }

    private static func leave(after last: Int) -> TimeInterval {
        leaves[(last % 6) / 2]
    }
}

private func smooth(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

private func mix(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ fraction: Double) -> SIMD2<Double> {
    a + (b - a) * fraction
}

private func length(_ vector: SIMD2<Double>) -> Double {
    (vector * vector).sum().squareRoot()
}
