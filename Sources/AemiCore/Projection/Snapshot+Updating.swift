extension Snapshot where Model: MutableCollection, Model.Element: Identifiable {
    /// A new snapshot with the element of matching id replaced — the fold
    /// that takes a buffer's `update()` result back into a projected list.
    /// Returns an equal snapshot when no id matches; never inserts.
    /// - Complexity: O(n) to locate the element.
    public func updating(_ element: Snapshot<Model.Element>) -> Snapshot<Model> {
        var models = wrappedValue
        guard let index = models.firstIndex(where: { $0.id == element.wrappedValue.id }) else {
            return self
        }
        models[index] = element.wrappedValue
        return Snapshot(models)
    }
}
