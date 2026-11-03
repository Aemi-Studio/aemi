import Foundation
import Testing

@testable import AemiProcess

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A `KERN_PROCARGS2` record: argc, executable path, padding, arguments, environment, then an empty string.
private func procargs(arguments: [String], environment: [String]) -> ArraySlice<UInt8> {
    let argc = UInt32(arguments.count)
    var bytes: [UInt8] = [UInt8(argc & 0xFF), UInt8(argc >> 8 & 0xFF), UInt8(argc >> 16 & 0xFF), UInt8(argc >> 24)]
    bytes += Array("/bin/tool".utf8) + [0, 0, 0]
    for string in arguments + environment { bytes += Array(string.utf8) + [0] }
    return ArraySlice(bytes + [0] + Array("ptr_munge=1".utf8) + [0])
}

@Suite struct ProcessTableTests {
    @Test func `the environment block starts after the arguments and ends at the first empty string`() {
        let block = ProcessTable.environmentBlock(
            procargs: procargs(arguments: ["tool", "A=argument"], environment: ["A=1", "TOKEN=x"])
        )
        let strings = block.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(strings == ["A=1", "TOKEN=x"])
        #expect(ProcessTable.environmentBlock(procargs: procargs(arguments: ["tool"], environment: [])).isEmpty)
        #expect(ProcessTable.environmentBlock(procargs: [1, 0]).isEmpty)
    }

    @Test func `the table lists the calling process with its parent, group and session`() throws {
        let me = try #require(ProcessTable.list().first { $0.pid == getpid() })
        #expect(me.parent == getppid())
        #expect(me.group == getpgrp())
        #expect(me.session == getsid(0))
        #expect(me.started > 0)
        #expect(ProcessTable.session(of: getpid()) == getsid(0))
        #expect(ProcessTable.session(of: Int32.max) == nil)
    }

    @Test func `the calling process's usage is read live`() throws {
        var spin: UInt64 = 0
        for value in 0 ..< 2_000_000 { spin &+= UInt64(value) &* 31 }
        #expect(spin != 1)
        let usage = try #require(ProcessTable.usage(of: getpid()))
        #expect(usage.cpuNanoseconds > 0)
        #expect(usage.footprintBytes > 0)
        #expect(usage.peakFootprintBytes >= usage.footprintBytes / 2)
        #expect(ProcessTable.usage(of: Int32.max) == nil)
    }

    /// A child that leads a new session, whose own child leaves its group: both are members of the session.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func `a session's members include a process that left its group`() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            // The child of a group leader can lead a new session; its own child then leaves the group.
            // Only the grandchild signals readiness, after setpgrp: the parent printing its pid raced the syscall.
            "use POSIX; $|=1; if (fork() == 0) { POSIX::setsid() or die; my $c = fork(); if ($c == 0) { setpgrp(0,0) or die; print getppid().\" $$\\n\"; sleep 30; exit 0 } sleep 30; exit 0 } sleep 30"
        ]
        process.environment = ["AEMI_PROCESS_TABLE_TEST": "token-\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { process.terminate() }
        let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        let pids = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try #require(pids.count == 2)
        let (leader, grandchild) = (pids[0], pids[1])
        defer {
            _ = kill(grandchild, SIGKILL)
            _ = kill(leader, SIGKILL)
        }
        let members = Set(ProcessTable.members(ofSession: leader).map(\.pid))
        #expect(members.contains(leader))
        #expect(members.contains(grandchild))
        let left = try #require(ProcessTable.list().first { $0.pid == grandchild })
        #expect(left.group == grandchild)
        #expect(left.session == leader)
        // Perl is an Apple platform binary on macOS, whose environment is hidden; on Linux it is readable.
        #if os(Linux)
            #expect(ProcessTable.environment(of: grandchild, contains: "AEMI_PROCESS_TABLE_TEST=token-\(getpid())"))
        #endif
        #expect(ProcessTable.send(SIGKILL, to: grandchild))
    }

    #if canImport(Darwin)
        @Test func `mach ticks convert to nanoseconds exactly`() {
            #expect(ProcessTable.nanoseconds(0) == 0)
            var info = mach_timebase_info_data_t()
            _ = mach_timebase_info(&info)
            #expect(ProcessTable.nanoseconds(UInt64(info.denom) * 1000) == UInt64(info.numer) * 1000)
            #expect(
                ProcessTable.nanoseconds(.max)
                    == (info.numer > info.denom
                        ? .max
                        : UInt64.max / UInt64(info.denom) * UInt64(info.numer) + (UInt64.max % UInt64(info.denom))
                            * UInt64(info.numer) / UInt64(info.denom))
            )
        }
    #endif
}
