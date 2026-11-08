import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

@MainActor
@Test func theArtworkRowNeedsATokenAndOKKeepsItsMode() throws {
    let without = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []), artwork: .off,
        hasToken: false)
    #expect(!without.artworkPopUp.isEnabled)
    #expect(without.artworkNote.stringValue == MappingSheet.needsTokenNote)
    let with = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []),
        artwork: .fillEmpty, hasToken: true)
    #expect(with.artworkPopUp.isEnabled)
    #expect(with.artworkPopUp.itemArray.map(\.title) == ["Off", "Fill Empty", "Replace"])
    #expect(with.artworkPopUp.indexOfSelectedItem == 1)
    with.artworkPopUp.selectItem(at: 2)
    _ = with.artworkPopUp.target?.perform(with.artworkPopUp.action, with: with.artworkPopUp)
    with.okButton.performClick(nil)
    #expect(with.result != nil)
    #expect(with.artwork == .replace)
    without.window?.close()
    with.window?.close()
}

@Test func theArtworkSettingIsOffUntilChosenAndKeptBesideTheMapping() throws {
    let schema = AppSettings()
    #expect(schema.discogsArtwork.defaultValue == .off)
    #expect(DiscogsArtworkMode.allCases.map(\.rawValue) == ["off", "fillEmpty", "replace"])
    // Not a field of the mapping: a saved mapping without it still reads.
    #expect(!DiscogsField.allCases.map(\.rawValue).contains("artwork"))
}
