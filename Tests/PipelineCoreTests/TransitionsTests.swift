import Testing
@testable import PipelineCore

func texts(_ old: Snapshot?, _ new: Snapshot) -> [String] {
    Transitions.events(from: old, to: new).map { "\($0.item.title) \($0.text)" }
}

func item(_ iid: Int, _ pipeline: Pipeline, role: Role = .authored) -> WatchItem {
    let key = MRKey(project: "a/b", iid: iid)
    return WatchItem(key: .mergeRequest(key), title: "MR \(iid)", url: key.url, role: role, projectName: "b",
                     lastCommitAt: nil, startedBy: nil, pipeline: pipeline)
}

@Test func firstSnapshotFiresNothing() {
    #expect(texts(nil, snapshot(mr(1, .authored, .failed))) == [])
}

@Test func ownPipelineFiresOnEachResult() {
    let before = snapshot(mr(1, .authored, .running), mr(2, .authored, .running), mr(3, .watched, .running))
    let after = snapshot(mr(1, .authored, .passed), mr(2, .authored, .failed), mr(3, .watched, .blocked))
    #expect(texts(before, after) == ["MR 1 Passed", "MR 2 Failed", "MR 3 Automatic stages green, waiting on "])
}

@Test func sameResultFiresOnce() {
    let done = snapshot(mr(1, .authored, .passed))
    #expect(texts(done, done) == [])
}

@Test func newPushThatRunsFiresNothing() {
    #expect(texts(snapshot(mr(1, .authored, .passed, id: 1)), snapshot(mr(1, .authored, .running, id: 2))) == [])
}

@Test func fastPipelineBetweenPollsFires() {
    #expect(texts(snapshot(mr(1, .authored, .passed, id: 1)), snapshot(mr(1, .authored, .passed, id: 2))) == ["MR 1 Passed"])
}

@Test func reviewerFiresOnPassedAndBlockedOnly() {
    let before = snapshot(mr(1, .reviewing, .running), mr(2, .reviewing, .running), mr(3, .reviewing, .running))
    let after = snapshot(mr(1, .reviewing, .passed), mr(2, .reviewing, .blocked), mr(3, .reviewing, .failed))
    #expect(texts(before, after).map { String($0.prefix(4)) } == ["MR 1", "MR 2"])
}

@Test func canceledFiresNothing() {
    #expect(texts(snapshot(mr(1, .authored, .running)), snapshot(mr(1, .authored, .canceled))) == [])
}

@Test func newItemWithResultFires() {
    #expect(texts(snapshot(), snapshot(mr(1, .reviewing, .passed))) == ["MR 1 Passed"])
}

@Test func textNamesFailedJobsAndManualStages() {
    let failed = Pipeline(id: 1, state: .failed, startedAt: nil, stages: [],
                          runningJobs: [], failedJobs: ["lint:code", "test:unit 2/4"])
    let blocked = Pipeline(id: 2, state: .blocked, startedAt: nil,
                           stages: [Stage(name: "e2e-regression", state: .blocked), Stage(name: "maintenance", state: .blocked)],
                           runningJobs: [], failedJobs: [])
    #expect(texts(snapshot(), snapshot(item(1, failed), item(2, blocked))) == [
        "MR 1 Failed: lint:code, test:unit 2/4",
        "MR 2 Automatic stages green, waiting on e2e-regression, maintenance",
    ])
}

@Test func blockedTextNamesAllowedFailures() {
    let blocked = Pipeline(id: 1, state: .blocked, startedAt: nil,
                           stages: [Stage(name: "e2e-smoke", state: .failed), Stage(name: "e2e-regression", state: .blocked)],
                           runningJobs: [], failedJobs: ["e2e:smoke: [1/3]"])
    #expect(texts(snapshot(), snapshot(item(1, blocked))) == [
        "MR 1 Automatic stages done, failed: e2e:smoke: [1/3], waiting on e2e-regression",
    ])
}

@Test func branchFiresOnEveryResultAndNamesWhoStartedIt() {
    let before = snapshot(branch("main", .running, id: 1), branch("dev", .running, id: 2))
    let after = snapshot(branch("main", .passed, id: 1), branch("dev", .failed, id: 2, by: "sam"))
    #expect(texts(before, after) == ["main Passed, by jane", "dev Failed, by sam"])
}
