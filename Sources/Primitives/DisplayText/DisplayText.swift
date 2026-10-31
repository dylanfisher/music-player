/// 312.4 -> "5:12", 3725 -> "1:02:05".
public func clock(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
    let tail = (rest < 10 ? "0" : "") + String(rest)
    if hours > 0 { return "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes):" + tail }
    return "\(minutes):" + tail
}

/// 44100 -> "44.1", 96000 -> "96", 705600 -> "705.6".
public func kilohertz(_ hertz: Double) -> String {
    let khz = hertz / 1000
    return khz.rounded() == khz ? String(Int(khz)) : String(khz)
}

/// 3 -> "★★★"; 0, unrated, -> "".
public func stars(_ count: Int) -> String {
    String(repeating: "★", count: max(0, count))
}

/// SF Symbol names more than one view draws.
public enum SymbolName {
    public static let playlist = "music.note.list"
}
