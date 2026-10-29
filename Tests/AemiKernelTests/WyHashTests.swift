import AemiKernel
import Testing

/// Against the reference `wyhash.h` (final 4.2), compiled with clang: its `test_vector.cpp`, where vector *i* is hashed
/// with seed *i*, and keys of every length class (≤ 3, 4–16, 17–47, the 48-byte loop and its edges) with seed 0, built
/// from `"abcdefghijklmnopqrstuvwxyz"` repeated (diary 2026-10-29-03).
private let referenceVectors: [(String, UInt64)] = [
    ("", 0x9322_8a4d_e0ee_c5a2), ("a", 0xc5ba_c3db_1787_13c4), ("abc", 0xa97f_2f7b_1d9b_3314),
    ("message digest", 0x786d_1f1d_f380_1df4), ("abcdefghijklmnopqrstuvwxyz", 0xdca5_a813_8ad3_7c87),
    ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", 0xb9e7_34f1_17cf_af70),
    (String(repeating: "1234567890", count: 8), 0x6cc5_eab4_9a92_d617)
]

private let lengthVectors: [(Int, UInt64)] = [
    (3, 0x989b_4a20_9c10_11c9), (4, 0x6d9a_9834_0374_10eb), (8, 0xb9a4_994f_5b68_615c),
    (16, 0x3530_9de4_5dc9_2e4a), (17, 0x9e0a_a4c6_1a2d_a95d), (47, 0x1f2d_e88f_ffcf_054b),
    (48, 0xd966_d4de_aea4_145c), (49, 0x0751_2018_83d8_db49), (96, 0x847b_734a_adcf_1a59),
    (97, 0x8e76_93f9_c118_e41e), (120, 0x30c6_12f0_d5ca_81dc), (150, 0xc5ba_c0eb_d7bb_a776)
]

struct WyHashTests {
    @Test(arguments: referenceVectors)
    func `the reference test vectors, seed = index`(text: String, expected: UInt64) {
        let vectors: [String] = [
            "", "a", "abc", "message digest", "abcdefghijklmnopqrstuvwxyz",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", String(repeating: "1234567890", count: 8)
        ]
        let seed = UInt64(vectors.firstIndex(of: text) ?? 0)
        let hash: UInt64 = WyHash.hash(Array(text.utf8), seed: seed)
        #expect(hash == expected)
    }

    @Test(arguments: lengthVectors)
    func `every length class, seed 0`(length: Int, expected: UInt64) {
        let key: [UInt8] = (0 ..< length).map { UInt8(97 + $0 % 26) }
        let hash: UInt64 = WyHash.hash(key)
        #expect(hash == expected)
    }
}
