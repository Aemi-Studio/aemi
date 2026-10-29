import AemiUnicode
import Testing

/// `UnicodeData` and simple case folding, promoted from AemiRegex with their generated tables (aemi ADR 0017). The tables are checked
/// against the standard library (independent data) and by their own invariants; AemiRegex's golden tests check what an engine does with
/// them against Go.
struct UnicodeDataTests {
    private static let codes = Array(
        "Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co Cn"
            .split(separator: " ").map(String.init))

    private static func code(_ category: Unicode.GeneralCategory) -> String {
        switch category {
            case .uppercaseLetter: "Lu"
            case .lowercaseLetter: "Ll"
            case .titlecaseLetter: "Lt"
            case .modifierLetter: "Lm"
            case .otherLetter: "Lo"
            case .nonspacingMark: "Mn"
            case .spacingMark: "Mc"
            case .enclosingMark: "Me"
            case .decimalNumber: "Nd"
            case .letterNumber: "Nl"
            case .otherNumber: "No"
            case .connectorPunctuation: "Pc"
            case .dashPunctuation: "Pd"
            case .openPunctuation: "Ps"
            case .closePunctuation: "Pe"
            case .initialPunctuation: "Pi"
            case .finalPunctuation: "Pf"
            case .otherPunctuation: "Po"
            case .mathSymbol: "Sm"
            case .currencySymbol: "Sc"
            case .modifierSymbol: "Sk"
            case .otherSymbol: "So"
            case .spaceSeparator: "Zs"
            case .lineSeparator: "Zl"
            case .paragraphSeparator: "Zp"
            case .control: "Cc"
            case .format: "Cf"
            case .surrogate: "Cs"
            case .privateUse: "Co"
            case .unassigned: "Cn"
            @unknown default: "Cn"
        }
    }

    // MARK: Categories

    @Test func `the tables say which Unicode version they are`() {
        #expect(UnicodeData.version == "17.0.0")
        #expect(UnicodeData.generalCategoryCodes.count == 29 && !UnicodeData.generalCategoryCodes.contains("Cn"))
    }

    @Test
    func
        `every character that is old enough to be in any platform's data has the category the standard library gives it`()
    {
        var owner = [Int8](repeating: -1, count: 0x110000)
        for (index, name) in Self.codes.enumerated() {
            guard let members = UnicodeData.generalCategory(name) else {
                Issue.record("no set for \(name)")
                return
            }
            for range in members.ranges { for value in range { owner[Int(value)] = Int8(index) } }
        }
        #expect(!owner.contains(-1), "the 30 categories must cover every scalar value")
        var mismatches: [String] = []
        var compared = 0
        for value in 0 ..< 0x110000 {
            // Assigned before Unicode 15: the data of any supported platform agrees on these.
            guard let scalar = Unicode.Scalar(UInt32(value)), let age = scalar.properties.age, age.major < 15 else {
                continue
            }
            compared += 1
            let expected = Self.code(scalar.properties.generalCategory)
            if Self.codes[Int(owner[value])] != expected, mismatches.count < 8 {
                mismatches.append(
                    "U+\(String(value, radix: 16)): table \(Self.codes[Int(owner[value])]), stdlib \(expected)")
            }
        }
        #expect(compared > 140_000, "compared only \(compared) scalars")
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test func `the groups, Cn, C and LC are what their members make them`() throws {
        func union(_ codes: [String]) throws -> UnicodeScalarSet {
            try codes.reduce(UnicodeScalarSet()) { try $0.union(#require(UnicodeData.generalCategory($1))) }
        }
        for (group, members) in UnicodeData.generalCategoryGroups where group != "C" {
            #expect(try UnicodeData.generalCategory(group) == union(members), "\(group)")
        }
        #expect(try UnicodeData.generalCategory("C") == union(["Cc", "Cf", "Co", "Cs", "Cn"]))
        #expect(try UnicodeData.generalCategory("LC") == union(["Lu", "Ll", "Lt"]))
        let assigned = try union(Self.codes.filter { $0 != "Cn" })
        #expect(UnicodeData.generalCategory("Cn") == assigned.negated())
        #expect(UnicodeData.unassigned == assigned.negated())
        #expect(UnicodeData.unassigned.contains(0x378), "U+0378 has been unassigned since Unicode 1.1")
    }

    @Test func `a long name is an alias, not a code`() {
        #expect(UnicodeData.generalCategoryAliases["Uppercase_Letter"] == "Lu")
        #expect(UnicodeData.generalCategory("Uppercase_Letter") == nil)
        #expect(UnicodeData.generalCategory("Lx") == nil && UnicodeData.generalCategory("") == nil)
    }

    // MARK: Scripts

    @Test func `the scripts are present, non-empty and never overlap`() throws {
        let names = UnicodeData.scriptNames
        #expect(names.count == 174)
        var owner = [Int16](repeating: -1, count: 0x110000)
        for (index, name) in names.enumerated() {
            let members = try #require(UnicodeData.script(name), "\(name)")
            #expect(!members.isEmpty, "\(name) is empty")
            for range in members.ranges {
                for value in range {
                    #expect(
                        owner[Int(value)] == -1,
                        "U+\(String(value, radix: 16)) is in \(name) and \(names[Int(max(owner[Int(value)], 0))])")
                    owner[Int(value)] = Int16(index)
                }
            }
        }
    }

    @Test func `well-known characters are in the script they belong to`() throws {
        func inside(_ script: String, _ scalar: Unicode.Scalar) throws -> Bool {
            try #require(UnicodeData.script(script)).ranges.contains { $0.contains(scalar.value) }
        }
        #expect(try inside("Greek", "α") && !inside("Greek", "a"))
        #expect(try inside("Latin", "a") && inside("Latin", "É") && !inside("Latin", "α"))
        #expect(try inside("Han", "日") && inside("Hiragana", "ひ") && inside("Katakana", "カ"))
        #expect(try inside("Cyrillic", "П") && inside("Common", " ") && inside("Inherited", "\u{0301}"))
    }

    @Test func `four-letter codes name scripts, and Script_Extensions holds the script and more`() throws {
        #expect(UnicodeData.scriptCodes["Latn"] == "Latin" && UnicodeData.scriptCodes["Grek"] == "Greek")
        let greek = try #require(UnicodeData.script("Greek"))
        let extended = try #require(UnicodeData.scriptExtensions("Greek"))
        #expect(greek.subtracting(extended).isEmpty, "every Greek character has Greek in its extensions")
        #expect(extended.contains(0x342), "U+0342 COMBINING GREEK PERISPOMENI is Inherited, extended to Greek")
        #expect(!greek.contains(0x342))
        #expect(UnicodeData.script("Grek") == nil, "a code is not a long name")
    }

    // MARK: Binary properties

    @Test func `binary properties are found by exact name, and their aliases are listed`() throws {
        let alphabetic = try #require(UnicodeData.binaryProperty("Alphabetic"))
        #expect(alphabetic.contains(0x61) && alphabetic.contains(0x3B1) && !alphabetic.contains(0x31))
        let space = try #require(UnicodeData.binaryProperty("White_Space"))
        #expect(space.contains(0x20) && space.contains(0x3000) && !space.contains(0x61))
        #expect(UnicodeData.binaryPropertyAliases["Alpha"] == "Alphabetic")
        #expect(UnicodeData.binaryProperty("Alpha") == nil, "an alias is not resolved")
        #expect(UnicodeData.binaryPropertyNames.count == 53)
    }

    // MARK: Case folding

    @Test func `fold orbits are closed, ascending, and found from every member`() throws {
        var members = 0
        for orbit in CaseFolding.simpleOrbits {
            #expect(orbit.count >= 2 && orbit == orbit.sorted(), "\(orbit)")
            for member in orbit {
                #expect(CaseFolding.simpleOrbit(of: member) == orbit, "U+\(String(member, radix: 16))")
            }
            members += orbit.count
        }
        #expect(members == CaseFolding.simpleOrbits.reduce(0) { $0 + $1.count })
        #expect(Set(CaseFolding.simpleOrbits.joined()).count == members, "no scalar is in two orbits")
        #expect(CaseFolding.simpleOrbit(of: 0x61)?.contains(0x41) == true)
        #expect(CaseFolding.simpleOrbit(of: 0x3000) == nil, "a scalar without case has no orbit")
    }

    @Test func `the orbits include the folds the case mappings alone would get wrong`() {
        #expect(CaseFolding.simpleOrbit(of: 0x6B) == [0x4B, 0x6B, 0x212A], "k, K and the Kelvin sign")
        #expect(CaseFolding.simpleOrbit(of: 0x73) == [0x53, 0x73, 0x17F], "s, S and the long s")
        #expect(CaseFolding.simpleOrbit(of: 0x3C3) == [0x3A3, 0x3C2, 0x3C3], "sigma, final sigma and capital sigma")
        #expect(CaseFolding.simpleOrbit(of: 0x69) == [0x49, 0x69], "dotless i is not folded with i (a Turkic mapping)")
        #expect(CaseFolding.simpleOrbit(of: 0x390) == [0x390, 0x1FD3], "an entry that exists only as a simple folding")
        #expect(CaseFolding.simpleOrbit(of: 0xFB05) == [0xFB05, 0xFB06], "the long-s t and st ligatures")
    }

    @Test func `folding a set adds the other members of every orbit it touches, and nothing else`() throws {
        #expect(
            UnicodeScalarSet(0x6B).simpleCaseClosure()
                == UnicodeScalarSet(normalizing: [0x4B ... 0x4B, 0x6B ... 0x6B, 0x212A ... 0x212A]))
        #expect(UnicodeScalarSet(0x3000).simpleCaseClosure() == UnicodeScalarSet(0x3000))
        let letters = UnicodeScalarSet(normalizing: [0x61 ... 0x7A])
        let folded = letters.simpleCaseClosure()
        #expect(folded.ranges.contains { $0.contains(0x41) } && folded.ranges.contains { $0.contains(0x17F) })
        #expect(folded.simpleCaseClosure() == folded, "folding twice changes nothing")
        let everything = UnicodeScalarSet(normalizing: [0 ... UnicodeScalarSet.maxScalar])
        #expect(everything.simpleCaseClosure() == everything)
    }
}
