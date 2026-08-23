/// Descriptions read as the raw value, so a log line shows `42`, not a wrapper.

extension Identifier: CustomStringConvertible {
    public var description: String {
        String(describing: rawValue)
    }
}

extension Identifier: CustomDebugStringConvertible {
    /// Names the owner, which is the part the raw value cannot show.
    public var debugDescription: String {
        "Identifier<\(Owner.self)>(\(rawValue))"
    }
}

extension Identifier: CustomPlaygroundDisplayConvertible {
    /// - Note: boxes the raw value into `Any`. Only a debugger or playground
    ///   calls this, so the allocation never lands in a shipping path.
    public var playgroundDescription: Any {
        rawValue
    }
}
