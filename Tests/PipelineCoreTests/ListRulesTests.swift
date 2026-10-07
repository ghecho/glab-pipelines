import Testing
@testable import PipelineCore

func key(_ iid: Int) -> ItemKey { .mergeRequest(MRKey(project: "a/b", iid: iid)) }

func titles(_ groups: [ListGroup]) -> [String] {
    groups.map { "\($0.title): " + $0.items.map(\.title).joined(separator: ", ") }
}

@Test func pinnedFirstThenNewestCommit() {
    let items = snapshot(
        mr(1, .authored, nil, committed: at("2026-10-07T10:00:00Z")),
        mr(2, .authored, nil, committed: at("2026-10-07T12:00:00Z")),
        mr(3, .authored, nil, committed: at("2026-10-07T09:00:00Z"))
    )
    let groups = ListRules.groups(items, pinned: [key(3)], hidden: [], showHidden: false)
    #expect(titles(groups) == ["Mine: MR 3, MR 2, MR 1"])
}

@Test func itemsWithoutDateGoLast() {
    let items = snapshot(mr(1, .authored, nil), mr(2, .authored, nil, committed: at("2026-10-07T09:00:00Z")))
    #expect(titles(ListRules.groups(items, pinned: [], hidden: [], showHidden: false)) == ["Mine: MR 2, MR 1"])
}

@Test func groupsComeInFixedOrderAndEmptyOnesAreDropped() {
    let items = snapshot(mr(1, .reviewing, nil), mr(2, .authored, nil))
    #expect(titles(ListRules.groups(items, pinned: [], hidden: [], showHidden: false)) == ["Mine: MR 2", "Reviewing: MR 1"])
}

@Test func hiddenItemsLeaveTheirGroup() {
    let items = snapshot(mr(1, .authored, nil), mr(2, .authored, nil))
    #expect(titles(ListRules.groups(items, pinned: [], hidden: [key(1)], showHidden: false)) == ["Mine: MR 2"])
}

@Test func showHiddenAddsADimmedGroupAtTheBottom() {
    let items = snapshot(mr(1, .authored, nil), mr(2, .reviewing, nil), branch("main", nil))
    let groups = ListRules.groups(items, pinned: [], hidden: [key(1), key(2)], showHidden: true)
    #expect(titles(groups) == ["Watched: main", "Hidden: MR 1, MR 2"])
    #expect(groups.map(\.dimmed) == [false, true])
}

@Test func hiddenWinsOverPinned() {
    let items = snapshot(mr(1, .authored, nil), mr(2, .authored, nil))
    let groups = ListRules.groups(items, pinned: [key(1)], hidden: [key(1)], showHidden: true)
    #expect(titles(groups) == ["Mine: MR 2", "Hidden: MR 1"])
}

@Test func watchedGroupCarriesErrorsEvenWithoutItems() {
    let missing = ItemKey.branch(BranchKey(project: "x/y", branch: "main"))
    let current = Snapshot(items: [], watchErrors: [missing: "No pipelines on this branch"], closedWatched: [])
    let groups = ListRules.groups(current, pinned: [], hidden: [], showHidden: false)
    #expect(groups == [ListGroup(title: "Watched", items: [], errors: [missing: "No pipelines on this branch"], dimmed: false)])
}

@Test func visibleEventsDropHiddenItems() {
    let events = Transitions.events(
        from: snapshot(mr(1, .authored, .running), mr(2, .authored, .running)),
        to: snapshot(mr(1, .authored, .passed), mr(2, .authored, .passed))
    )
    #expect(ListRules.visibleEvents(events, hidden: [key(1)]).map(\.item.title) == ["MR 2"])
}
