# CI

The pinned swift-ci graph reads `action.json`; run its checks locally with
`swift-ci run <check>`. macOS debug covers Swift 6.4.1 and 6.3.3; release runs
nightly or manually on the primary toolchain. Tests are serial because Swift
6.3 shares its test executor across stress suites. CI keeps the 250 ms compiler
budget and Xcode 26.6 selection.

Do not enable whole-package Linux tests: AemiCore requires Combine. The caller
retains its cached build of the eleven Linux products consumed by the tools.
All Unicode generators, Embedded builds, native/Rosetta kernel checks, Linux
ARM and real x86 sanitizer/fuzz checks, analyzer-script tests and release-note
fixtures remain independent jobs. The final result now waits for all of them.

The new formatting gate covers package-layout files except generated/fixture
code and the legacy AemiCore/AemiUI/AemiTesting trees and their test suites.
Those trees already fail current formatting; this migration does not reformat
them. Static analyzers are not newly imposed on aemi's legacy backlog. The old
reusable workflows remain for external callers, with the workflow SHA context
corrected to job.workflow_sha.
