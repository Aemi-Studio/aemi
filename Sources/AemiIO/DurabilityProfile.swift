/// How a write reaches stable storage when a channel is synced.
///
/// The distinction mirrors the platform primitives: a *barrier* orders this
/// file's writes ahead of later ones without forcing a device cache flush,
/// while *full* additionally asks the drive to flush its cache (power-loss
/// durable, significantly slower). `none` skips syncing entirely.
public enum DurabilityProfile: Sendable, Equatable {
    /// Ordering barrier (`F_BARRIERFSYNC` on Darwin, `fdatasync` on Linux):
    /// crash-consistent, but a power loss may drop the last few writes.
    case barrier
    /// Device cache flush (`F_FULLFSYNC` on Darwin, `fsync` on Linux):
    /// power-loss durable, significantly slower.
    case full
    /// No syncing. Benchmarks and throwaway data only.
    case none
}
