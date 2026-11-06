import Testing
@testable import GhuppyCore

struct TabDragTests {
    private func drag(from index: Int, by translation: Double) -> TabDrag {
        TabDrag(index: index, count: 4, slot: 100, translation: translation)
    }

    @Test func landsOnTheSlotItsCentreHasReached() {
        #expect(drag(from: 1, by: 0).target == 1)
        #expect(drag(from: 1, by: 49).target == 1)
        #expect(drag(from: 1, by: 51).target == 2)
        #expect(drag(from: 1, by: 151).target == 3)
        #expect(drag(from: 2, by: -49).target == 2)
        #expect(drag(from: 2, by: -51).target == 1)
    }

    @Test func stopsAtEitherEndOfTheBar() {
        #expect(drag(from: 1, by: 900).target == 3)
        #expect(drag(from: 1, by: 900).offset == 200)
        #expect(drag(from: 1, by: -900).target == 0)
        #expect(drag(from: 1, by: -900).offset == -100)
    }

    @Test func tabsItHasPassedMakeWay() {
        let right = drag(from: 1, by: 160)
        #expect([0, 2, 3].map(right.shift(ofTabAt:)) == [0, -100, -100])

        let left = drag(from: 3, by: -160)
        #expect([0, 1, 2].map(left.shift(ofTabAt:)) == [0, 100, 100])

        let stayed = drag(from: 1, by: 20)
        #expect([0, 2, 3].map(stayed.shift(ofTabAt:)) == [0, 0, 0])
    }

    @Test func staysPutBeforeTheBarHasBeenMeasured() {
        let drag = TabDrag(index: 1, count: 4, slot: 0, translation: 80)
        #expect(drag.target == 1)
        #expect(drag.offset == 0)
    }
}
