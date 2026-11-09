import Testing

@testable import DiscogsTagger
@testable import Settings
@testable import TagWriter

@Test func aDraftStartsFromAPresetAndEditsARule() {
    var draft = MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: [])
    #expect(draft.chosenName == DiscogsPreset.oneToOne.name)
    #expect(draft.choices.map(\.name) == DiscogsPreset.all.map(\.name))
    draft.use(DiscogsPreset.minimal.name)
    #expect(draft.mapping == DiscogsPreset.minimal.mapping)

    draft.setTargets("mood, STYLE_TOO", for: .styles)
    #expect(draft.mapping[.styles].targets == [.field(.mood), .key("STYLE_TOO")])
    #expect(draft.targetsText(.styles) == "mood, STYLE_TOO")
    #expect(draft.chosenName == nil, "edited")
    draft.mapping[.styles].mode = .fillEmpty
    draft.mapping[.styles].setJoin("")
    #expect(draft.problem == "styles is a list, so it needs a join")
    draft.mapping[.styles].setJoin("; ")
    draft.mapping[.genres].setTemplate("{genre} - {styles}")
    #expect(draft.mapping[.genres].format.template == "{genre} - {styles}")
    #expect(draft.problem == nil)
}

@Test func aKeySpelledPerFormatIsShownButNotEditedAsText() {
    var draft = MappingDraft(mapping: DiscogsPreset.yate.mapping, saved: [])
    let spelled = DiscogsField.allCases.first { !draft.targetsEditable($0) }
    guard let spelled else {
        Issue.record("YATE spells some key per format")
        return
    }
    let before = draft.mapping[spelled].targets
    draft.setTargets("comment", for: spelled)
    #expect(draft.mapping[spelled].targets == before)
}

@Test func aSavedMappingNeedsANameThatIsntAPresets() {
    var draft = MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: [])
    #expect(draft.save(as: " ") == "has no name")
    #expect(draft.save(as: DiscogsPreset.minimal.name) != nil)
    #expect(draft.save(as: "Mine") == nil)
    draft.mapping[.label].mode = .off
    #expect(draft.save(as: "Mine") == nil)
    #expect(draft.saved.map(\.name) == ["Mine"], "replaced, not added")
    #expect(draft.saved[0].mapping[.label].mode == .off)
    #expect(draft.chosenName == "Mine")
}

@Test func theTemplateHelpListsEveryTokenTheCheckAccepts() {
    #expect(TemplateHelp.tokens.map(\.token) == DiscogsMapping.templateNames)
    #expect(Set(DiscogsMapping.templateNames).count == DiscogsField.allCases.count + 1)
    for token in DiscogsMapping.templateNames {
        #expect(TemplateHelp.text.contains(token), "\(token)")
    }
    for example in TemplateHelp.examples {
        #expect(TemplateHelp.text.contains(example.template))
        var mapping = DiscogsPreset.oneToOne.mapping
        mapping[.genres].format.template = example.template
        #expect(mapping.problem() == nil, "\(example.template) is a template the check accepts")
    }
    #expect(TemplateHelp.text.contains("outside braces is kept as written"))
}

@Test func anImportedMappingIsShownUnsavedAndABadOneChangesNothing() {
    var yate = MappingDraft(mapping: DiscogsPreset.yate.mapping, saved: [])
    yate.mapping[.styles].setJoin("; ")
    var draft = MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: [])
    #expect(draft.load(yate.exported, from: "Pasted") == nil)
    #expect(draft.mapping == yate.mapping)
    #expect(draft.chosenName == nil)
    #expect(draft.note == "Pasted, not saved; Save As keeps it")

    let before = draft
    var broken = DiscogsPreset.oneToOne.mapping
    broken[.styles].format.join = nil
    for bad in [
        "", "{", "[1]", "{\"styles\": 1}", MappingDraft(mapping: broken, saved: []).exported,
    ] {
        #expect(draft.load(bad, from: "Pasted") != nil, "\(bad)")
        #expect(draft == before, "\(bad) changed nothing")
    }
    #expect(
        draft.load(MappingDraft(mapping: broken, saved: []).exported, from: "Pasted")
            == "styles is a list, so it needs a join")
}
