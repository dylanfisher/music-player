/// The master volume as Denon's protocol counts it, in half-decibel steps from `MV00`, the
/// minimum at −80 dB, to `MV98` at +18 dB; `MV80` is 0 dB and `MV805` is +0.5 dB.
public struct ReceiverVolume: Equatable, Sendable {
    /// 0 is the minimum and 196 is +18 dB.
    let halfSteps: Int
    static let halfStepRange = 0...196

    init?(halfSteps: Int) {
        guard Self.halfStepRange.contains(halfSteps) else { return nil }
        self.halfSteps = halfSteps
    }

    /// From an `MV` parameter: two digits, `00` to `98`, or three ending in 5 for a half
    /// step, `005` to `975`. `99` is the minimum too, as the X1000's spec says in one place†.
    init?(parameter: Substring) {
        guard parameter.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        switch parameter.count {
        case 2:
            guard let whole = Int(parameter) else { return nil }
            self.init(halfSteps: whole == 99 ? 0 : whole * 2)
        case 3:
            guard parameter.last == "5", let whole = Int(parameter.prefix(2)), whole < 98 else {
                return nil
            }
            self.init(halfSteps: whole * 2 + 1)
        default:
            return nil
        }
    }

    /// From the text the owner gives, in decibels as the receiver shows them: "-30", "-30.5",
    /// "+3", "0". Nil unless it's a whole or half decibel from −80 to +18.
    public init?(decibels text: String) {
        guard text.utf8.count <= 8, text.allSatisfy({ "+-.0123456789".contains($0) }),
            let value = Double(text),
            (value * 2).rounded() == value * 2
        else { return nil }
        self.init(halfSteps: Int(value * 2) + 160)
    }

    /// The `MV` parameter that sets it.
    var parameter: String {
        let whole = halfSteps / 2
        let digits = whole < 10 ? "0\(whole)" : "\(whole)"
        return halfSteps % 2 == 0 ? digits : digits + "5"
    }

    public var decibels: Double { Double(halfSteps) / 2 - 80 }

    /// Text that isn't a level `init(decibels:)` takes.
    public struct Refusal: Error, CustomStringConvertible {
        public let text: String

        public init(text: String) { self.text = text }

        public var description: String {
            "\(text.debugDescription) isn't a level from -80 to +18 dB in half steps"
        }
    }
}
