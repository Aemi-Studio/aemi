/// Extra spacing that equalizes the height of paired rows once lines wrap independently in each pane.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum RowAlignment {
    /// - Returns: Spacing to append below each row of each side so that row `i` is as tall on both sides.
    ///   A side shorter than the other gets zero-height rows appended, so both results have the same count.
    /// - Complexity: O(rows)
    public static func spacing(left: [Double], right: [Double]) -> (left: [Double], right: [Double]) {
        let count = max(left.count, right.count)
        var leftSpacing = [Double](repeating: 0, count: count)
        var rightSpacing = [Double](repeating: 0, count: count)
        for row in 0 ..< count {
            let leftHeight = row < left.count ? left[row] : 0
            let rightHeight = row < right.count ? right[row] : 0
            let target = max(leftHeight, rightHeight)
            leftSpacing[row] = target - leftHeight
            rightSpacing[row] = target - rightHeight
        }
        return (leftSpacing, rightSpacing)
    }
}
