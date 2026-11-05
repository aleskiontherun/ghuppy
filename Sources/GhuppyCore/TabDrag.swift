/// A tab being dragged along the tab bar, whose tabs all take up the same
/// width. Nothing moves in the tab order until the drag ends: until then the
/// dragged tab follows the pointer and the tabs it has passed make way.
public struct TabDrag: Equatable, Sendable {
    /// Where the dragged tab was picked up.
    public let index: Int
    public let count: Int
    /// The distance from one tab to the next.
    public let slot: Double
    public let translation: Double

    public init(index: Int, count: Int, slot: Double, translation: Double) {
        self.index = index
        self.count = count
        self.slot = slot
        self.translation = translation
    }

    /// How far the dragged tab has moved, which stops at either end of the bar.
    public var offset: Double {
        min(max(translation, -Double(index) * slot), Double(count - 1 - index) * slot)
    }

    /// The position the dragged tab takes if dropped now.
    public var target: Int {
        slot > 0 ? index + Int((offset / slot).rounded()) : index
    }

    /// How far the tab at `position` moves aside to make way.
    public func shift(ofTabAt position: Int) -> Double {
        if index < position, position <= target { return -slot }
        if target <= position, position < index { return slot }
        return 0
    }
}
