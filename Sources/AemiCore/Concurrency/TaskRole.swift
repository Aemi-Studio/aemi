/// Categorizes work spawned through a ``TaskProvider``.
///
/// The role has **no effect in production**: ``DefaultTaskProvider`` spawns every task identically
/// regardless of role. It is purely a test-observability hint. A tracking ``TaskProvider`` double
/// uses it to decide which spawned tasks to await for completion (``work``) and which to merely
/// cancel on teardown (``observation``). Choose the role that matches the work's lifetime so test
/// doubles can reason about it — but do not expect it to change scheduling, priority, or
/// cancellation in the shipping app.
public enum TaskRole: Sendable {
    /// Finite work that a test can await to completion.
    case work
    /// A flow-lifetime observer (e.g. a stream-consuming loop). Test doubles exclude these
    /// when waiting for all tasks, since they only finish when their input ends or they are
    /// cancelled.
    case observation
}
