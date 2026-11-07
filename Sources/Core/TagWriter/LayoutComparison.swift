import Foundation
import Metadata

/// The blocks `edit` shouldn't have touched that differ between `original` and `edited`: each
/// field, picture and other block outside the edit must be there, in the same order, byte for
/// byte. Headers, padding and chunk offsets change with the edit, and the audio is compared by
/// hash elsewhere, so they're left out, as are blocks the edit added.
package func untouchedBlockDifferences(original: URL, edited: URL, edit: TagEdit)
    throws(MetadataError) -> [String]
{
    let before = try kept(readTagLayout(at: original), edit)
    let afterPaths = Set(before.map(\.path))
    let after = try kept(readTagLayout(at: edited), edit).filter { afterPaths.contains($0.path) }
    guard before.map(\.path) == after.map(\.path) else {
        return [
            "blocks differ: \(before.map(\.path).joined(separator: ", "))"
                + " became \(after.map(\.path).joined(separator: ", "))"
        ]
    }
    do throws(ParseFailure) {
        let old = try FileSource(path: original.path)
        let new = try FileSource(path: edited.path)
        var differences: [String] = []
        for (a, b) in zip(before, after) {
            if a.range.count != b.range.count {
                differences.append("\(a.path) at \(a.range.lowerBound) changed size")
            } else if try old.read(a.range) != new.read(b.range) {
                differences.append("\(a.path) at \(a.range.lowerBound) changed")
            }
        }
        return differences
    } catch {
        throw error.error(path: edited.path)
    }
}

private func kept(_ layout: TagLayout, _ edit: TagEdit) -> [TagBlock] {
    let edited = Set(edit.values.keys)
    let editedCustom = Set(edit.custom.keys.map { $0.uppercased() })
    return layout.blocks.filter { block in
        switch block.kind {
        case .field:
            block.fields.isDisjoint(with: edited)
                && !(block.customKey.map(editedCustom.contains) ?? false)
        case .art: edit.art == nil
        case .other: true
        case .header, .padding, .chunkOffsets, .audio: false
        }
    }
}
