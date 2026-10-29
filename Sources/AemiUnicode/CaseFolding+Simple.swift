/// Simple case folding as orbits: the scalars that fold to each other (`k`, `K` and the Kelvin sign), generated from Go's tables with
/// the categories (`UnicodeDataTables`, one Unicode version). The standard library's case mappings are not enough: derived from them
/// the orbits are wrong in five places, among them `ı`, which a mapping relates to `I` and simple folding does not. Promoted from
/// AemiRegex (aemi ADR 0018).
extension CaseFolding {
    /// The members of the orbit `scalar` belongs to, ascending, or nil when it has no case partners.
    /// - Complexity: O(log orbits).
    public static func simpleOrbit(of scalar: UInt32) -> [UInt32]? {
        let index = UnicodeDataTables.foldIndex
        var low = 0
        var high = index.count / 2 - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = index[2 * middle]
            if candidate == scalar {
                var members: [UInt32] = []
                var cursor = Int(index[2 * middle + 1])
                while UnicodeDataTables.foldOrbits[cursor] != 0 {
                    members.append(UnicodeDataTables.foldOrbits[cursor])
                    cursor += 1
                }
                return members
            }
            if candidate < scalar { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// Every orbit, each ascending.
    public static let simpleOrbits: [[UInt32]] = {
        var result: [[UInt32]] = []
        var current: [UInt32] = []
        for value in UnicodeDataTables.foldOrbits {
            if value == 0 {
                result.append(current)
                current = []
            } else {
                current.append(value)
            }
        }
        return result
    }()
}
