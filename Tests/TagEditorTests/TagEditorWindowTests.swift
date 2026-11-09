import AppKit
import Testing
import WindowPlacement

@testable import Metadata
@testable import TagEditor

private func track(_ path: String, title: String? = nil, release: String? = nil)
    -> EditableTrack
{
    var tags = TrackTags()
    tags.title = title
    tags.custom[DiscogsKey.releaseID] = release
    return EditableTrack(path: path, tags: tags, pictures: [])
}

/// The window opens laid out as it stays: every tab's label fits, and filling in the fields,
/// for files with a release id or without, moves nothing (phase 57).
@MainActor @Test func nothingMovesWhenTheFieldsFillIn() throws {
    for release in [nil, "42"] {
        let editor = TagEditorWindow(paths: ["/music/a.flac"])
        editor.show(after: nil)
        defer { editor.close() }
        editor.window.displayIfNeeded()
        #expect(editor.tabs.minimumSize.width <= editor.tabs.frame.width, "the tab bar fits")
        // The size it was given before it showed is the one its content takes once shown.
        #expect(editor.window.contentView?.fittingSize == editor.window.contentMinSize)
        let frames = { () -> [NSRect] in
            editor.fields.values.joined().map { $0.convert($0.bounds, to: nil) }
                .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        }
        let window = editor.window.frame
        let tabs = editor.tabs.frame
        let fields = frames()
        #expect(!fields.isEmpty, "the fields are there before the files are read")

        editor.load(
            TagEditorModel(tracks: [
                track(
                    "/music/a.flac",
                    title: "A title long enough to fill its field and then some more",
                    release: release)
            ]))
        editor.window.displayIfNeeded()
        #expect(editor.window.frame == window)
        #expect(editor.tabs.frame == tabs)
        #expect(editor.shownTabs == TagEditorTab.allCases)
        #expect(frames() == fields)
    }
}

/// Every tab fits the tab view's least height, so showing the window or another tab never
/// makes it grow.
@MainActor @Test func everyTabFitsTheWindowAsItOpens() throws {
    let editor = TagEditorWindow(paths: ["/music/a.flac"])
    editor.show(after: nil)
    defer { editor.close() }
    editor.window.displayIfNeeded()
    let window = editor.window.frame
    for tab in TagEditorTab.allCases {
        editor.tabs.selectTabViewItem(withIdentifier: tab.rawValue)
        editor.window.displayIfNeeded()
        #expect(editor.window.frame == window, "\(tab)")
        #expect(editor.window.contentView?.fittingSize == editor.window.contentMinSize, "\(tab)")
    }
    editor.tabs.selectTabViewItem(withIdentifier: TagEditorTab.info.rawValue)
}

/// The window resizes, the tabs and fields taking the room, no smaller than its layout, and
/// the next window opens at the frame it was left at (ADR 0158).
@MainActor @Test func theWindowResizesAndKeepsItsFrame() throws {
    let editor = TagEditorWindow(paths: ["/music/a.flac"])
    #expect(editor.window.styleMask.contains(.resizable))
    editor.show(after: nil)
    editor.window.displayIfNeeded()
    let tabs = editor.tabs.frame
    let title = try #require(editor.fields[.title]?.first)
    let titleWidth = title.frame.width

    let screen = try #require(editor.window.screen ?? NSScreen.main).visibleFrame
    let grown = NSRect(
        x: screen.minX + 20, y: screen.maxY - 20 - (editor.window.frame.height + 120),
        width: editor.window.frame.width + 200, height: editor.window.frame.height + 120)
    editor.window.setFrame(grown, display: true)
    editor.window.layoutIfNeeded()
    #expect(editor.tabs.frame.height == tabs.height + 120)
    #expect(editor.tabs.frame.width == tabs.width + 200)
    #expect(title.frame.width > titleWidth)
    #expect(PlacedWindows.shared.frames[TagEditorWindow.frameName] == grown)
    editor.close()

    let next = TagEditorWindow(paths: ["/music/b.flac"])
    next.show(after: nil)
    defer { next.close() }
    #expect(next.window.frame == grown)
}

/// A window opened while another is open cascades from it, at its size.
@MainActor @Test func aSecondWindowCascadesFromTheLastOneOpen() throws {
    let first = TagEditorWindow(paths: ["/music/a.flac"])
    first.show(after: nil)
    defer { first.close() }
    let second = TagEditorWindow(paths: ["/music/b.flac"])
    second.show(after: first.window)
    defer { second.close() }
    #expect(second.window.frame.size == first.window.frame.size)
    #expect(second.window.frame.minX > first.window.frame.minX)
    #expect(second.window.frame.maxY < first.window.frame.maxY)
}
