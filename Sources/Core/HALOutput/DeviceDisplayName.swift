/// The name the app shows for a device: its own name without a serial number in parentheses at
/// its end, as RME's DACs name themselves (`ADI-2 DAC (57850288)`), unless another of `names`
/// reads the same without one, and then in full, since the serial is what tells them apart.
/// `names` is every output device's own name, `name` among them.
public func deviceDisplayName(_ name: String, among names: [String]) -> String {
    let short = withoutSerial(name)
    guard short != name, names.filter({ withoutSerial($0) == short }).count <= 1 else {
        return name
    }
    return short
}

/// Six or more digits, which a model number in parentheses, such as `(2)`, never is.
private func withoutSerial(_ name: String) -> String {
    guard name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex,
        name[name.index(before: open)] == " "
    else { return name }
    let digits = name[name.index(after: open)..<name.index(before: name.endIndex)]
    guard digits.count >= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return name }
    return String(name[..<name.index(before: open)])
}
