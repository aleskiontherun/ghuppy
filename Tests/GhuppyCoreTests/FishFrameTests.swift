import Foundation
import Testing
@testable import GhuppyCore

struct FishFrameTests {
    private let crossing = SpinnerFrame.crossingDuration
    private let rotation = 75 * Double.pi / 180

    private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    private func isFish(_ frame: FishFrame) -> Bool {
        let fish = FishFrame.fish
        return zip(frame.dots, fish.dots).allSatisfy {
            distance($0.position, $1.position) < 1e-9 && abs($0.growth - $1.growth) < 1e-9
        // The same lines, though it may trace them from another dot or the
        // other way round.
        } && frame.outline.count == fish.outline.count
            && frame.outline.allSatisfy { point in fish.outline.contains { distance($0, point) < 1e-9 } }
    }

    @Test func restsAsTheLogoWithASmallEye() {
        let fish = FishFrame.fish
        #expect(fish.dots.count == 3)
        #expect(fish.dots[0].growth == 1)
        #expect(fish.dots[1].growth == 1)
        #expect(fish.dots[2].growth == 0)
        // The tail nodes one above the other at the left edge, the eye to the right.
        #expect(abs(fish.dots[0].position.x + FishFrame.width) < 1e-9)
        #expect(abs(fish.dots[1].position.x + FishFrame.width) < 1e-9)
        #expect(fish.dots[0].position.y < 0 && fish.dots[1].position.y > 0)
        #expect(fish.dots[2].position.x > 0.5)
        // The head of the line reaches the right edge.
        #expect(abs((fish.outline.map(\.x).max() ?? 0) - FishFrame.width) < 1e-9)
    }

    @Test func linesSetOffAtOnceWhileTheEyeGrowsWhereItIs() {
        let fish = FishFrame.fish
        let early = FishFrame(at: 0.1)
        #expect(early.dots[2].position == fish.dots[2].position)
        #expect(early.dots[2].growth > 0 && early.dots[2].growth < 1)
        #expect(early.dots[0].position != fish.dots[0].position)
        #expect(zip(early.outline, fish.outline).contains { distance($0, $1) > 1e-3 })
    }

    @Test func eyeIsAFullDotOnTheLineBeforeTheFirstCrossingEnds() {
        let frame = FishFrame(at: crossing * 0.75)
        #expect(frame.dots[2].growth == 1)
        #expect(frame.outline.contains { distance($0, frame.dots[2].position) < 1e-9 })
    }

    @Test func runsAsTheTurnedCirclingSpinnerBetweenFirstAndLastCrossings() {
        for step in 0...300 {
            let time = crossing + Double(step) / 300 * 9 * crossing
            let frame = FishFrame(at: time)
            let spinner = SpinnerFrame(at: time, rotation: rotation, circling: true)
            for dot in frame.dots {
                #expect(dot.growth == 1)
                #expect(spinner.dots.contains { distance($0, dot.position) < 1e-9 })
            }
        }
    }

    @Test func settlesAtTheEndOfACycleWithAWholeCrossingToUntangle() {
        for elapsed in stride(from: 0.0, through: 5, by: 0.01) {
            let settles = FishFrame.settles(stoppingAt: elapsed)
            let cycles = settles / FishFrame.cycle
            #expect(abs(cycles - cycles.rounded()) < 1e-9)
            #expect(settles >= FishFrame.cycle)
            #expect(settles - crossing >= elapsed - 1e-9)
            #expect(settles - crossing < elapsed + FishFrame.cycle)
            #expect(!FishFrame.isUntangling(at: elapsed, settles: settles))
        }
    }

    @Test func comesBackToTheLogoAndStaysThere() {
        // Last crossings falling on each part of the circling dot's lap.
        for elapsed in [0.0, 0.2, 0.6, 1.3, 2.3, 2.71, 3.3, 4.4] {
            let settles = FishFrame.settles(stoppingAt: elapsed)
            #expect(isFish(FishFrame(at: settles, settles: settles)))
            #expect(isFish(FishFrame(at: settles + 1, settles: settles)))
        }
    }

    @Test(arguments: [1.3, 2.3, 3.3])
    func neverJumps(stoppingAt stop: TimeInterval) {
        // Settling at 2s, 3s and 4s, at each part of the circling dot's lap.
        // Like the triangle spinner's, its dots and lines swap places in its
        // arrays from one crossing to the next, so each is checked against
        // the nearest.
        let settles = FishFrame.settles(stoppingAt: stop)
        let step = 0.001
        var previous = FishFrame(at: 0, settles: settles)
        for index in 1...Int((settles + 0.1) / step) {
            let frame = FishFrame(at: Double(index) * step, settles: settles)
            for dot in frame.dots {
                let nearest = previous.dots.min {
                    distance($0.position, dot.position) < distance($1.position, dot.position)
                }!
                #expect(distance(dot.position, nearest.position) < 0.03)
                #expect(abs(dot.growth - nearest.growth) < 0.03)
            }
            for point in frame.outline {
                #expect(previous.outline.contains { distance($0, point) < 0.03 })
            }
            previous = frame
        }
    }

    @Test func eyeLeavesTheLineAndShrinksWhereItIsAtTheEnd() {
        let settles = FishFrame.settles(stoppingAt: 0.2)
        let eye = FishFrame.fish.dots[2]
        let late = FishFrame(at: settles - 0.05, settles: settles)
        #expect(late.dots[2].position == eye.position)
        #expect(late.dots[2].growth > 0 && late.dots[2].growth < 1)
    }
}
