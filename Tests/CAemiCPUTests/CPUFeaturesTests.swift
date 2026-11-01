import CAemiCPU
import Testing

#if canImport(Darwin)
    import Darwin
#endif

@Suite
struct CPUFeaturesTests {
    #if canImport(Darwin) && arch(arm64)
        private static func sysctlFlag(_ name: String) -> Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 && value != 0
        }

        @Test(arguments: [
            ("hw.optional.arm.FEAT_SHA3", ADF_CPU_SHA3), ("hw.optional.arm.FEAT_SHA512", ADF_CPU_SHA512),
            ("hw.optional.arm.FEAT_DotProd", ADF_CPU_DOTPROD), ("hw.optional.arm.FEAT_I8MM", ADF_CPU_I8MM),
            ("hw.optional.arm.FEAT_PMULL", ADF_CPU_PMULL), ("hw.optional.armv8_crc32", ADF_CPU_CRC32),
            ("hw.optional.arm.FEAT_AES", ADF_CPU_AES), ("hw.optional.arm.FEAT_BF16", ADF_CPU_BF16),
            ("hw.optional.arm.FEAT_SME", ADF_CPU_SME)
        ])
        func `each arm64 feature is what sysctl says`(name: String, feature: UInt64) {
            #expect((adf_cpu_features() & feature != 0) == Self.sysctlFlag(name), "\(name)")
        }
    #endif

    @Test
    func `the set names one architecture's features only, and the same set every time`() {
        let features = adf_cpu_features()
        #if arch(arm64)
            #expect(features & ADF_CPU_NEON != 0)
            #expect(features >> 32 == 0)
        #elseif arch(x86_64)
            #expect(features & ADF_CPU_SSE2 != 0)
            #expect(features & 0xFFFF_FFFF == 0)
        #endif
        #expect(adf_cpu_features() == features)
    }
}

@Suite
struct TimingSafeTests {
    @Test
    func `a scope turns data-independent timing on, nests, and restores what it found`() {
        let supported = adf_cpu_features() & ADF_CPU_DIT != 0
        #expect(adf_cpu_timing_safe_is_on() == 0)
        let outer = adf_cpu_timing_safe_begin()
        #expect((adf_cpu_timing_safe_is_on() == 1) == supported)
        let inner = adf_cpu_timing_safe_begin()
        adf_cpu_timing_safe_end(inner)
        #expect((adf_cpu_timing_safe_is_on() == 1) == supported, "an inner scope's end leaves the outer one on")
        adf_cpu_timing_safe_end(outer)
        #expect(adf_cpu_timing_safe_is_on() == 0)
    }

    #if arch(arm64) && canImport(Darwin)
        @Test
        func `Apple silicon from M1 on has DIT`() {
            #expect(adf_cpu_features() & ADF_CPU_DIT != 0)
        }
    #endif
}
