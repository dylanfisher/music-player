/// Where Keep Files Organized has got after a write's tags are written (ADR 0186): renaming
/// the files, then pointing Undo Tag Edit's records at their new paths, then updating the
/// library's index with them.
public enum OrganizeStep: Equatable, Sendable {
    case moving(OrganizeProgress)
    case updatingUndo
    case updatingLibrary
}
