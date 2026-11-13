import AppKit
import DisplayText
import Library

extension LibraryBrowser {
    /// Import Moves…: applies the move list at `list` with `importing`, then says over `window`
    /// what it moved, and lists the lines that moved nothing in the Problems window, where ⌘C
    /// copies them.
    public func importMoves(
        from list: URL, over window: NSWindow,
        by importing: @escaping (URL) async throws -> MoveListImport
    ) {
        guard !isImportingMoves else { return beep() }
        isImportingMoves = true
        show(failure: "Importing the moves in \(terminalSafe(list.lastPathComponent))…")
        Task {
            defer { isImportingMoves = false }
            let result: MoveListImport
            do {
                result = try await importing(list)
            } catch {
                return report(terminalSafe("couldn't import the moves in \(list.path): \(error)"))
            }
            finish(
                result.summary, result.problems.map { Problem($0.description) },
                as: \.importedMovesReport)
            refreshNow()
            runHealth()
            edited()
            tell(result.summary, result.detail, window)
        }
    }
}
