// MARK: - String Helpers

extension String {
    func paddedToTwo() -> String {
        count < 2 ? "0" + self : self
    }
}
