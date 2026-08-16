// Canonical decomposition mirroring String.normalize("NFD") in the engine
// that generated the tables. Swift 6.3 exposes no public NFD API, so the
// decomposition mappings are table-driven (recursively pre-expanded by the
// generator) plus the UAX #15 Hangul arithmetic.
//
// Combining classes come from the Swift stdlib — the one input here that is
// not engine-derived (ccc is not observable from JavaScript). ccc values are
// stable by Unicode policy for assigned scalars; the parity fixtures cover
// multi-mark reordering in both source orders to keep this honest.

/// Scalar construction from values valid by construction — a caseless-enum namespace shared by `NFD` and
/// `CaseFolding`.
enum UnicodeScalarMath {
    /// Builds a scalar from a value that is valid by construction — Hangul jamo arithmetic, engine-derived
    /// NFD payloads, or ASCII case math — so the failable initializer never yields nil at these sites.
    @inline(__always)
    static func valid(_ v: UInt32) -> Unicode.Scalar {
        // swift-format-ignore: NeverForceUnwrap
        Unicode.Scalar(v)!
    }
}

public enum NFD {
    public static func decompose(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count + scalars.count / 4)
        for s in scalars {
            appendDecomposition(of: s, to: &out)
        }
        canonicalReorder(&out)
        return out
    }

    private static func appendDecomposition(of s: Unicode.Scalar, to out: inout [Unicode.Scalar]) {
        let v = s.value
        if v < 0xC0 {
            // Below U+00C0 nothing decomposes (lowest table entry is À) — skip
            // the binary search for the ASCII bulk of real corpora.
            out.append(s)
            return
        }
        if v >= 0xAC00, v <= 0xD7A3 {
            // Hangul syllable → L V [T] jamo.
            let sIndex = v - 0xAC00
            out.append(UnicodeScalarMath.valid(0x1100 + sIndex / 588))
            out.append(UnicodeScalarMath.valid(0x1161 + (sIndex % 588) / 28))
            let t = sIndex % 28
            if t > 0 { out.append(UnicodeScalarMath.valid(0x11A7 + t)) }
            return
        }
        if let payload = UnicodeSets.nfdDecomposition(of: v) {
            // Payload scalars come from real engine output; always valid.
            for p in payload { out.append(UnicodeScalarMath.valid(p)) }
            return
        }
        out.append(s)
    }

    /// Canonical Ordering Algorithm: stably move each nonzero-ccc scalar past
    /// any directly preceding higher-ccc scalars (equal classes keep order).
    static func canonicalReorder(_ scalars: inout [Unicode.Scalar]) {
        guard scalars.count > 1 else { return }
        for i in 1 ..< scalars.count where scalars[i].value >= 0x300 {
            let ccc = combiningClass(scalars[i])
            guard ccc > 0 else { continue }
            var j = i
            while j > 0, combiningClass(scalars[j - 1]) > ccc {
                scalars.swapAt(j - 1, j)
                j -= 1
            }
        }
    }

    static func combiningClass(_ s: Unicode.Scalar) -> UInt8 {
        s.properties.canonicalCombiningClass.rawValue
    }
}
