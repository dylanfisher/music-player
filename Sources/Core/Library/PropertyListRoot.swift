import Foundation

/// `data` read as a property list whose top level is a dictionary, as another program's
/// `Library.xml` and preferences are. `refused` makes the error from why it isn't one.
func propertyListRoot(_ data: Data, refused: (String) -> PlayerImportError)
    throws(PlayerImportError) -> [String: Any]
{
    let root: Any
    do {
        root = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
        throw refused("not a property list: \(error.localizedDescription)")
    }
    guard let root = root as? [String: Any] else {
        throw refused("its top level isn't a dictionary")
    }
    return root
}
