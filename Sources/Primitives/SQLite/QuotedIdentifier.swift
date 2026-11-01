/// `name` as an SQL identifier, in double quotes with any inside doubled, for a table name read
/// back from the database rather than written in the source. `execute` runs every statement in
/// its text, so an unquoted name could end one statement and start another.
public func quotedIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
