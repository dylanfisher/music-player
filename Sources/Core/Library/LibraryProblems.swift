extension LibraryIndex {
    /// Keeps `lines` out of the Problems window from now on (ADR 0053). A line is the problem as
    /// the window showed it, so the same problem found again stays dismissed.
    func dismissProblems(_ lines: [String]) throws {
        try database.transaction {
            let insert = try statement(
                "INSERT OR IGNORE INTO \(dismissedProblemsTable) (line) VALUES (?)")
            for line in lines { try insert.run(line) }
        }
    }

    /// Every line the user dismissed.
    func dismissedProblems() throws -> Set<String> {
        Set(try statement("SELECT line FROM \(dismissedProblemsTable)").map { try $0.text(0) })
    }
}
