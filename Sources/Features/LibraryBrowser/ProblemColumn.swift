import Foundation

/// A column of the Problems window, by which it can sort (ADR 0175).
enum ProblemColumn: String, CaseIterable {
    case kind, track, file, folder, detail

    var title: String {
        switch self {
        case .kind: "Kind"
        case .track: "Track"
        case .file: "File"
        case .folder: "Folder"
        case .detail: "Detail"
        }
    }

    /// Its width before the user changes it.
    var width: CGFloat {
        switch self {
        case .kind: 110
        case .track: 170
        case .file: 170
        case .folder: 220
        case .detail: 320
        }
    }

    /// What it shows of `problem`: the file's name and its folder, from the path.
    func text(_ problem: Problem) -> String {
        switch self {
        case .kind: problem.kind
        case .track: problem.track ?? ""
        case .file: problem.path.map { ($0 as NSString).lastPathComponent } ?? ""
        case .folder: problem.path.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        case .detail: problem.detail
        }
    }
}
