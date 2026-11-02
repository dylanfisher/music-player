/// Random tokens for keys, so a URL names what it serves without saying what it is (ADR 0039).
/// A key keeps its token until the token is `lifetimeSeconds` old; the map ends with the
/// server's session.
struct TokenMap<Key: Hashable> {
    let lifetimeSeconds: Double
    private var byToken: [String: (key: Key, issued: Double)] = [:]
    private var byKey: [Key: String] = [:]

    init(lifetimeSeconds: Double) {
        self.lifetimeSeconds = lifetimeSeconds
    }

    /// The key's live token, or a new one: 128 bits from the system's random generator, which
    /// on Darwin is `arc4random_buf`, a cryptographic one.
    mutating func token(for key: Key, now: Double) -> String {
        if let token = byKey[key], let entry = byToken[token], now - entry.issued < lifetimeSeconds
        {
            return token
        }
        dropExpired(now: now)
        var generator = SystemRandomNumberGenerator()
        let token = (0..<2).map { _ in generator.next() as UInt64 }
            .map { String($0, radix: 16).leftPadded(to: 16) }.joined()
        byToken[token] = (key, now)
        byKey[key] = token
        return token
    }

    /// The key a live token stands for; nil for an unknown or expired one.
    func key(for token: String, now: Double) -> Key? {
        guard let entry = byToken[token], now - entry.issued < lifetimeSeconds else { return nil }
        return entry.key
    }

    private mutating func dropExpired(now: Double) {
        for (token, entry) in byToken where now - entry.issued >= lifetimeSeconds {
            byToken[token] = nil
            if byKey[entry.key] == token { byKey[entry.key] = nil }
        }
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
