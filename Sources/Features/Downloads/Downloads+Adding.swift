import AppKit
import Discogs
import Foundation
import Library
import Metadata
import Recommender
import Settings

/// Add's menu in the Downloads window: upgrades, the library's selection, a pasted Discogs
/// release and the not-found upgrades, each queued through the queue sheet.
extension Downloads {
    /// Queues by `addition`.
    func add(_ addition: DownloadAddition) {
        guard let session, session.canTag else { return }
        let setup = session.setup
        switch addition {
        case .upgrades:
            guard let share = upgradeShare(setup) else { return }
            Task {
                let found = await blockingFileWork {
                    Result { () throws -> ([UpgradeCandidate], Set<Int>) in
                        let index = try LibraryIndex(at: setup.databaseURL)
                        return (
                            try index.upgradeCandidates(onShare: share),
                            try index.neverUpgradeReleases()
                        )
                    }
                }
                let candidates: [UpgradeCandidate]
                let never: Set<Int>
                do {
                    (candidates, never) = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                chooseAndQueue(
                    heading: "Upgrades",
                    note:
                        "Lossy albums whose every track carries one Discogs release id. A lossless"
                        + " copy replaces each; Approve deletes the old files. Never Upgrade"
                        + " keeps an album out of the automatic upgrades.",
                    QueueChoice.upgrades(candidates, never: never), upgrade: true,
                    tickingAll: false, other: QueueChoice.neverUpgradeTitle
                ) { marked in
                    self.write("The albums weren't marked Never Upgrade") { index in
                        try index.setNeverUpgrade(true, releases: marked.compactMap(\.releaseID))
                    }
                }
            }
        case .notFound:
            guard let share = upgradeShare(setup) else { return }
            Task {
                let found = await blockingFileWork {
                    Result { () throws -> [QueueChoice] in
                        let index = try LibraryIndex(at: setup.databaseURL)
                        return QueueChoice.setAside(
                            try index.upgradeCandidates(onShare: share),
                            misses: try index.upgradeMisses())
                    }
                }
                let choices: [QueueChoice]
                do {
                    choices = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                guard !choices.isEmpty else {
                    return alert("Nothing to queue", ["No automatic upgrade was set aside."])
                }
                let sheet = QueueSheet(
                    heading: "Upgrades Not Found",
                    note: Self.notFoundNote(autoUpgrade: autoUpgrade),
                    choices: choices, policies: [.flac], tickingAll: false,
                    button: Self.queueAgainTitle)
                present(sheet) {
                    guard let again = sheet.result?.choices else { return }
                    self.write("The albums weren't queued again") { index in
                        try index.clearUpgradeMisses(releases: again.compactMap(\.releaseID))
                    } then: {
                        self.upgradeAutomatically()
                    }
                }
            }
        case .fromSelection:
            let selected: [Int64]
            do {
                selected = try selectedTracks()
            } catch {
                return alert("The selection couldn't be read", ["\(error)"])
            }
            guard !selected.isEmpty else {
                return alert(
                    "No tracks are selected", ["Select an album's tracks in the library first."])
            }
            queueFromSelection(selected, asked: true)
        case .pasteRelease: askForRelease()
        }
    }

    /// From Library Selection for `tracks`. `asked` is false for the one opening the window
    /// offers, which shows nothing unless the tracks hold an album to queue, and gives way to
    /// any sheet begun while the albums are read.
    func queueFromSelection(_ tracks: [Int64], asked: Bool) {
        guard let session else { return }
        let database = session.setup.databaseURL
        let begun = sheetsBegun
        Task {
            let found = await blockingFileWork {
                Result { try LibraryIndex(at: database).discogsAlbums() }
            }
            let albums: [DiscogsAlbum]
            do {
                albums = try found.get()
            } catch {
                return alert("The library couldn't be read", ["\(error)"])
            }
            let choices = QueueChoice.selection(tracks, albums: albums)
            if !asked {
                guard choices.contains(where: { $0.refusal == nil }), sheetsBegun == begun,
                    controller?.window?.attachedSheet == nil
                else { return }
            }
            chooseAndQueue(
                heading: "From Library Selection",
                note: "The albums of the selected tracks, each downloaded as its release.",
                choices, upgrade: false, tickingAll: true)
        }
    }

    /// The library's share, which an upgrade's old files are kept by; nil, with an alert, when
    /// the staging folder isn't on it.
    private func upgradeShare(_ setup: Setup) -> String? {
        guard let share = setup.share else {
            alert(
                "Upgrades need the staging folder on the library's share",
                ["An upgrade's old files are kept by their path on the share."])
            return nil
        }
        return share
    }

    /// Not Found's button.
    static let queueAgainTitle = "Queue Again"

    /// Not Found's note, saying when Queue Again queues nothing until the box is on.
    static func notFoundNote(autoUpgrade: Bool) -> String {
        let box = AppSettings().autoUpgrade.title
        let note =
            "Albums \(box) set aside after searching four times. \(queueAgainTitle) clears"
            + " their misses"
        return autoUpgrade
            ? note + ", so it queues them in turn."
            : note + "; with \(box) off, nothing is queued until it's turned on."
    }

    /// Runs `change` on the index off the main thread, then `then`; an alert headed `failure`
    /// when it threw.
    private func write(
        _ failure: String, _ change: @escaping @Sendable (LibraryIndex) throws -> Void,
        then: @escaping () -> Void = {}
    ) {
        guard let database = session?.setup.databaseURL else { return }
        Task {
            let done = await blockingFileWork { Result { try change(LibraryIndex(at: database)) } }
            do {
                try done.get()
                then()
            } catch {
                alert(failure, ["\(error)"])
            }
        }
    }

    func chooseAndQueue(
        heading: String, note: String, _ choices: [QueueChoice], upgrade: Bool,
        tickingAll: Bool, other: String? = nil, marked: @escaping ([QueueChoice]) -> Void = { _ in }
    ) {
        guard !choices.isEmpty else {
            return alert(
                "Nothing to queue",
                [upgrade ? "No library album can be upgraded." : "The selection holds no album."])
        }
        let queueSheet = QueueSheet(
            heading: heading, note: note, choices: choices,
            policies: FormatPolicy.offered(upgrade: upgrade), tickingAll: tickingAll,
            other: other)
        present(queueSheet) {
            if let chosen = queueSheet.marked { return marked(chosen) }
            guard let chosen = queueSheet.result else { return }
            self.queue(chosen.choices, chosen.policy)
        }
    }

    private func askForRelease() {
        guard let window = controller?.window else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "1234567 or https://www.discogs.com/release/1234567"
        field.frame = NSRect(x: 0, y: 30, width: 340, height: 24)
        let policies = FormatPolicy.offered(upgrade: false)
        let popUp = formatPopUp(policies)
        popUp.frame = NSRect(x: 0, y: 0, width: 200, height: 26)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(popUp)
        let question = NSAlert()
        question.messageText = "Paste a Discogs release"
        question.informativeText =
            "Its id or its page's address. It must be in this Mac's Discogs catalog."
        question.accessoryView = accessory
        question.addButton(withTitle: QueueSheet.queueTitle)
        question.addButton(withTitle: "Cancel")
        question.window.initialFirstResponder = field
        question.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let id = pastedReleaseID(field.stringValue) else {
                self.alert(
                    "That isn't a Discogs release",
                    ["\(field.stringValue.debugDescription) has no release id."])
                return
            }
            self.queue(
                [
                    QueueChoice(
                        title: DownloadRow.releaseName(id), detail: "", releaseID: id, upgrade: nil,
                        refusal: nil)
                ],
                policies[popUp.indexOfSelectedItem])
        }
    }

    /// Builds each choice's snapshot from the catalog and queues them, saying which failed.
    private func queue(_ choices: [QueueChoice], _ policy: FormatPolicy) {
        guard let session else { return }
        let catalog = session.setup.catalog
        Task {
            var orders: [(snapshot: ReleaseSnapshot, order: JobOrder)] = []
            var problems: [String] = []
            for choice in choices {
                guard let release = choice.releaseID, let order = choice.order(policy) else {
                    problems.append(
                        "\(choice.title): can't be queued as \(DownloadRow.policyName(policy))")
                    continue
                }
                let built = await blockingFileWork {
                    Result { try ReleaseSnapshot.queueable(releaseID: release, catalogAt: catalog) }
                }
                switch built {
                case .success(let snapshot): orders.append((snapshot, order))
                case .failure(let error): problems.append("\(choice.title): \(error)")
                }
            }
            problems += await session.model.create(orders)
            if !problems.isEmpty {
                alert(
                    "\(problems.count) of \(choices.count) weren't queued", problems)
            }
        }
    }
}
