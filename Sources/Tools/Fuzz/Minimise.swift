/// The shortest input found that still fails, by removing ever smaller ranges and keeping each
/// removal that still fails. Stops after `attempts` tries.
func minimise(_ input: [UInt8], attempts: Int, stillFails: ([UInt8]) -> Bool) -> [UInt8] {
    var current = input
    var tries = 0
    var chunk = max(1, current.count / 2)
    while tries < attempts, !current.isEmpty {
        var start = 0
        var removed = false
        while start < current.count, tries < attempts {
            var candidate = current
            candidate.removeSubrange(start..<min(start + chunk, current.count))
            tries += 1
            if stillFails(candidate) {
                current = candidate
                removed = true
            } else {
                start += chunk
            }
        }
        if !removed {
            guard chunk > 1 else { break }
            chunk /= 2
        }
        chunk = min(chunk, max(1, current.count))
    }
    return current
}
