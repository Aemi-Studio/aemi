/// Unicode character properties by their exact names, from generated tables of one Unicode version, so a lookup means the same on
/// every platform and nothing is scanned at run time: general categories (with the UAX #44 groups), scripts and their
/// Script_Extensions, and binary properties. Promoted from AemiRegex (aemi ADR 0018); how a pattern language spells names (loosely,
/// with aliases of its own) is that language's business, built on these.
public enum UnicodeData {
    /// The Unicode version of the categories, scripts and case folding.
    public static let version = UnicodeDataTables.unicodeVersion

    /// The 29 two-letter general categories, in the tables' order. `Cn` is not listed: it is everything else.
    public static let generalCategoryCodes: [String] = UnicodeDataTables.categoryCodes.split(separator: " ")
        .map(String.init)

    /// The long names of the general categories, spelled exactly, with their codes: `Uppercase_Letter` is `Lu`.
    public static let generalCategoryAliases: [String: String] = pairs(UnicodeDataTables.categoryAliases)

    /// The members of each one-letter group. `C` also holds every unassigned code point (``generalCategory(_:)`` adds `Cn`).
    public static let generalCategoryGroups: [String: [String]] = [
        "L": ["Lu", "Ll", "Lt", "Lm", "Lo"], "M": ["Mn", "Mc", "Me"], "N": ["Nd", "Nl", "No"],
        "P": ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"], "S": ["Sm", "Sc", "Sk", "So"], "Z": ["Zs", "Zl", "Zp"],
        "C": ["Cc", "Cf", "Co", "Cs"]
    ]

    /// The general category with this code: a two-letter one (`Lu`), a one-letter group (`L`, where `C` includes `Cn`), `Cn`
    /// (unassigned), or `LC` (cased letters). Nil for anything else, a long name included.
    /// - Complexity: O(ranges in the set).
    public static func generalCategory(_ code: String) -> UnicodeScalarSet? {
        if code == "LC" { return union(["Lu", "Ll", "Lt"]) }
        if let members = generalCategoryGroups[code] {
            return code == "C" ? union(members).union(unassigned) : union(members)
        }
        if code == "Cn" { return unassigned }
        guard let index = generalCategoryCodes.firstIndex(of: code) else { return nil }
        return ranges(UnicodeDataTables.categoryData, UnicodeDataTables.categoryOffsets, index)
    }

    /// Every scalar value that is in none of the 29 listed categories: `Cn`.
    public static var unassigned: UnicodeScalarSet {
        var listed: [ClosedRange<UInt32>] = []
        for index in generalCategoryCodes.indices {
            listed += ranges(UnicodeDataTables.categoryData, UnicodeDataTables.categoryOffsets, index).ranges
        }
        return UnicodeScalarSet(normalizing: listed).negated()
    }

    /// The scripts' long names, in the tables' order (`Latin`, `Old_Italic`).
    public static let scriptNames: [String] = UnicodeDataTables.scriptNames.split(whereSeparator: \.isWhitespace)
        .map(String.init)

    /// The four-letter script codes, with the long names they stand for: `Latn` is `Latin`.
    public static let scriptCodes: [String: String] = pairs(UnicodePropertyTables.scriptCodes)

    /// The Script property of the script with this long name, spelled exactly; nil when there is none.
    public static func script(_ name: String) -> UnicodeScalarSet? {
        scriptNames.firstIndex(of: name)
            .map { ranges(UnicodeDataTables.scriptData, UnicodeDataTables.scriptOffsets, $0) }
    }

    /// The Script_Extensions of the script with this long name, spelled exactly; nil when there is none.
    public static func scriptExtensions(_ name: String) -> UnicodeScalarSet? {
        scriptNames.firstIndex(of: name)
            .map {
                ranges(UnicodePropertyTables.scriptExtensionData, UnicodePropertyTables.scriptExtensionOffsets, $0)
            }
    }

    /// The binary properties' names, in the tables' order (`Alphabetic`, `White_Space`).
    public static let binaryPropertyNames: [String] = UnicodePropertyTables.binaryNames
        .split(
            whereSeparator: \.isWhitespace
        )
        .map(String.init)

    /// The binary properties' aliases, spelled exactly, with the names they stand for: `Alpha` is `Alphabetic`.
    public static let binaryPropertyAliases: [String: String] = pairs(UnicodePropertyTables.binaryAliases)

    /// The binary property with this name, spelled exactly (an alias is not resolved); nil when there is none.
    public static func binaryProperty(_ name: String) -> UnicodeScalarSet? {
        binaryPropertyNames.firstIndex(of: name)
            .map { ranges(UnicodePropertyTables.binaryData, UnicodePropertyTables.binaryOffsets, $0) }
    }

    private static func union(_ codes: [String]) -> UnicodeScalarSet {
        var result: [ClosedRange<UInt32>] = []
        for code in codes {
            guard let index = generalCategoryCodes.firstIndex(of: code) else { continue }
            result += ranges(UnicodeDataTables.categoryData, UnicodeDataTables.categoryOffsets, index).ranges
        }
        return UnicodeScalarSet(normalizing: result)
    }

    /// The ranges of table `index` of a generated table, which stores each as an inclusive `lo, hi` pair.
    private static func ranges(_ data: [UInt32], _ offsets: [Int], _ index: Int) -> UnicodeScalarSet {
        var result: [ClosedRange<UInt32>] = []
        result.reserveCapacity(offsets[index + 1] - offsets[index])
        for range in offsets[index] ..< offsets[index + 1] { result.append(data[2 * range] ... data[2 * range + 1]) }
        return UnicodeScalarSet(normalizing: result)
    }

    /// `a=b c=d` as a dictionary.
    private static func pairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: "=")
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }
}
