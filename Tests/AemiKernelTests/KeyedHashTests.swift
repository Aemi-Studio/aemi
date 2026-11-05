import AemiKernel
import Testing

/// SipHash-2-4 against OpenSSL 3.5.9's `SIPHASH` MAC (the paper's function: the shared rounds, the tail and the length byte), and
/// SipHash-1-3 against CPython 3's `hash(bytes)` with `PYTHONHASHSEED=0`, which is SipHash-1-3 under the zero key. Two
/// implementations independent of this one; the messages are `00 01 02 …` of each length, or the text shown.
private let sip24Key = KeyedHash(k0: 0x0706_0504_0302_0100, k1: 0x0F0E_0D0C_0B0A_0908)
private let sip24: [(Int, UInt64)] = [
    (0, 0x726F_DB47_DD0E_0E31), (1, 0x74F8_39C5_93DC_67FD), (3, 0x8567_6696_D7FB_7E2D), (7, 0xAB02_00F5_8B01_D137),
    (8, 0x93F5_F579_9A93_2462), (9, 0x9E00_82DF_0BA9_E4B0), (15, 0xA129_CA61_49BE_45E5), (16, 0x3F2A_CC7F_57C2_9BDB),
    (17, 0x699A_E9F5_2CBE_4794), (31, 0x32D8_92FA_D841_C342), (32, 0x7127_512F_72F2_7CCE), (63, 0x958A_324C_EB06_4572)
]
/// Key `f0 e1 d2 c3 b4 a5 96 87 78 69 5a 4b 3c 2d 1e 0f`, message byte *i* = `(7i + 3) mod 256`.
private let sip24OtherKey: [(Int, UInt64)] = [
    (0, 0x63FC_4360_A74E_3E78), (5, 0xFFA7_E6AB_7432_7BA6), (24, 0x5E61_A143_52AC_6F59)
]
private let sip13: [(Int, UInt64)] = [
    (1, 0x68A9_1412_8E01_E473), (3, 0x4D4C_9A4A_8EF6_E0AD), (7, 0x2F09_8AB0_C751_325A), (8, 0xEAD4_11E6_7EBE_2EEA),
    (9, 0x7592_7F9D_9512_4362), (15, 0xF30E_B725_BB91_C9EA), (16, 0x8972_1884_33A5_C5B7), (17, 0x4883_C49A_2C00_9C1D),
    (31, 0x1697_3944_3111_D49B), (32, 0x31EF_8061_C910_629B), (63, 0x385D_3E39_E5F3_7359)
]
private let sip13Text: [(String, UInt64)] = [
    ("name", 0xA8FF_84C1_2D48_CFA6), ("version", 0x83D8_9FBF_D823_6492), ("dependencies", 0xB74F_F737_E0E2_98B5),
    ("abcdefghijklmnopqrstuvwxyz", 0x323C_CD2F_D307_09DF)
]

struct KeyedHashTests {
    @Test(arguments: sip24)
    func `SipHash-2-4 matches OpenSSL`(length: Int, expected: UInt64) {
        let message = (0 ..< length).map { UInt8($0) }
        #expect(message.withUnsafeBytes { unsafe sip24Key.hash24($0) } == expected)
    }

    @Test(arguments: sip24OtherKey)
    func `SipHash-2-4 matches OpenSSL under another key`(length: Int, expected: UInt64) {
        let key = KeyedHash(k0: 0x8796_A5B4_C3D2_E1F0, k1: 0x0F1E_2D3C_4B5A_6978)
        let message = (0 ..< length).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        #expect(message.withUnsafeBytes { unsafe key.hash24($0) } == expected)
    }

    @Test(arguments: sip13)
    func `SipHash-1-3 matches CPython under the zero key`(length: Int, expected: UInt64) {
        #expect(KeyedHash(k0: 0, k1: 0).hash((0 ..< length).map { UInt8($0) }) == expected)
    }

    @Test(arguments: sip13Text)
    func `SipHash-1-3 of text matches CPython`(text: String, expected: UInt64) {
        #expect(KeyedHash(k0: 0, k1: 0).hash(Array(text.utf8)) == expected)
    }

    @Test func `a tweak hashes as its eight bytes before the message, and every overload agrees`() {
        let key = KeyedHash(k0: 0x1234, k1: 0x5678)
        let tweak: UInt64 = 0x0102_0304_0506_0708
        for length in 0 ..< 40 {
            let message = (0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) }
            var joined: [UInt8] = []
            withUnsafeBytes(of: tweak.littleEndian) { joined.append(contentsOf: $0) }
            joined += message
            #expect(key.hash(tweak: tweak, message[...]) == key.hash(joined))
            #expect(key.hash(message[...]) == key.hash(message))
            #expect(message.withUnsafeBytes { unsafe key.hash($0) } == key.hash(message))
        }
    }

    @Test func `the process key is fixed for the process and differs from the zero key unless asked for`() {
        #expect(KeyedHash.process == KeyedHash.process)
        let deterministic = unsafe getenv("SWIFT_DETERMINISTIC_HASHING") != nil
        #expect((KeyedHash.process == KeyedHash(k0: 0, k1: 0)) == deterministic)
    }
}

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
