import DisplayText
import Recommender

/// What the status bar says once the service has kept the profile: "Sent 6,541 albums, 1,741
/// with a release id; 12 newly queued for the community sync".
func profileSentSummary(_ receipt: ProfileReceipt) -> String {
    "Sent \(count(receipt.albums, "album")), \(number(receipt.withReleaseID)) with a release id;"
        + " \(number(receipt.queued)) newly queued for the community sync"
}
