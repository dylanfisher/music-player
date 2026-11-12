import Foundation
import Library
import Metadata

extension Downloads {
    /// The service's own limit on a machine's name.
    nonisolated static let machineNameCap = 64

    /// This Mac's name for leases and claims: the ID the library index names its sync log by,
    /// which is the same on every launch and on no other Mac. Reads the index off the calling
    /// thread.
    package nonisolated static func machineName(databaseURL: URL) async throws -> String {
        try await blockingFileWork {
            Result { String(try LibraryIndex(at: databaseURL).machineID().prefix(machineNameCap)) }
        }.get()
    }
}
