import Testing

@testable import MusicPlayer

@Test func removingTakesOnlyFromTheListWithTheKeys() {
    func target(_ queue: Bool, _ queueSelection: Bool, _ tracks: Bool, _ playlist: Bool) -> Removal?
    {
        removalTarget(
            queueFocused: queue, queueHasSelection: queueSelection, tracksFocused: tracks,
            canRemoveFromPlaylist: playlist)
    }
    #expect(target(true, true, false, true) == .queue)
    #expect(target(true, false, false, true) == nil)
    #expect(target(false, true, true, true) == .playlist)
    // The sidebar, a pane or anything else: nothing, even with selections in both lists.
    #expect(target(false, true, false, true) == nil)
    #expect(target(false, false, true, false) == nil)
}
