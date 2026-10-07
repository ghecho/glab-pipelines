import Foundation
import Testing
@testable import PipelineCore

@Test(arguments: [
    ("CREATED", PipelineState.running), ("WAITING_FOR_RESOURCE", .running), ("PREPARING", .running),
    ("WAITING_FOR_CALLBACK", .running), ("PENDING", .running), ("RUNNING", .running),
    ("SCHEDULED", .running), ("CANCELING", .running), ("SUCCESS", .passed), ("FAILED", .failed),
    ("MANUAL", .blocked), ("CANCELED", .canceled), ("SKIPPED", .canceled),
])
func mapsEveryGitLabStatus(status: String, state: PipelineState) throws {
    #expect(try PipelineState(gitlab: status) == state)
}

@Test func mapsLowerCaseStageStatuses() throws {
    #expect(try PipelineState(gitlab: "manual") == .blocked)
    #expect(try PipelineState(gitlab: "success") == .passed)
}

@Test func rejectsUnknownStatus() {
    #expect(throws: DecodeError.unknownStatus("WOBBLING")) { try PipelineState(gitlab: "WOBBLING") }
}

@Test(arguments: [
    "https://gitlab.com/example/group/app/-/merge_requests/123",
    "https://gitlab.com/example/group/app/-/merge_requests/123/diffs",
    "https://gitlab.com/example/group/app/-/merge_requests/123?tab=pipelines",
    "https://gitlab.com/example/group/app/-/merge_requests/123#note_123",
])
func parsesMergeRequestURLs(text: String) {
    let key = MRKey(url: URL(string: text)!)
    #expect(key == MRKey(project: "example/group/app", iid: 123))
}

@Test(arguments: [
    "https://github.com/a/b/-/merge_requests/1",
    "https://gitlab.com/a/b/-/merge_requests/",
    "https://gitlab.com/a/b/-/pipelines/12",
    "https://gitlab.com/-/merge_requests/1",
])
func rejectsOtherURLs(text: String) {
    #expect(MRKey(url: URL(string: text)!) == nil)
}

@Test func buildsMergeRequestURL() {
    let key = MRKey(project: "a/b", iid: 7)
    #expect(key.url.absoluteString == "https://gitlab.com/a/b/-/merge_requests/7")
    #expect(MRKey(url: key.url) == key)
}

@Test func parsesNumericIDs() throws {
    #expect(try numericID("gid://gitlab/Ci::Pipeline/1234567890") == 1234567890)
    #expect(throws: DecodeError.badID("gid://gitlab/Ci::Pipeline/x")) { try numericID("gid://gitlab/Ci::Pipeline/x") }
}

@Test(arguments: [
    ("https://gitlab.com/a/b/-/tree/main", "main"),
    ("https://gitlab.com/a/b/-/commits/main", "main"),
    ("https://gitlab.com/a/b/-/tree/feature/fix-login", "feature/fix-login"),
    ("https://gitlab.com/a/b/-/tree/main?ref_type=heads", "main"),
    ("https://gitlab.com/a/b/-/tree/main/", "main"),
    ("https://gitlab.com/a/b/-/commits/main#top", "main"),
])
func parsesBranchURLs(text: String, branch: String) {
    #expect(WatchInput(text) == .item(.branch(BranchKey(project: "a/b", branch: branch))))
}

@Test func parsesPipelineURLs() {
    #expect(WatchInput("https://gitlab.com/a/b/-/pipelines/1234567890") == .pipeline(project: "a/b", id: 1234567890))
    #expect(WatchInput("  https://gitlab.com/a/b/-/pipelines/12/builds ") == .pipeline(project: "a/b", id: 12))
}

@Test func parsesMergeRequestInput() {
    #expect(WatchInput("https://gitlab.com/a/b/-/merge_requests/7/diffs") == .item(.mergeRequest(MRKey(project: "a/b", iid: 7))))
}

@Test(arguments: [
    "hello",
    "https://github.com/a/b/-/tree/main",
    "https://gitlab.com/a/b/-/tree/",
    "https://gitlab.com/a/b/-/pipelines/x",
    "https://gitlab.com/a/b",
])
func rejectsOtherWatchInput(text: String) {
    #expect(WatchInput(text) == nil)
}

@Test func mergeRequestKeyRoundTrips() {
    let key = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 3))
    #expect(ItemKey(url: key.url) == key)
}

@Test(arguments: ["main", "feature/fix-login", "feature/a b"])
func branchURLRoundTrips(branch: String) {
    let key = ItemKey.branch(BranchKey(project: "a/b", branch: branch))
    #expect(ItemKey(url: key.url) == key)
}

@Test func branchPipelinesURLFiltersByBranch() {
    #expect(BranchKey(project: "a/b", branch: "feature/x").pipelinesURL.absoluteString
            == "https://gitlab.com/a/b/-/pipelines?ref=feature/x")
}

func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

func mr(_ iid: Int, _ role: Role, _ state: PipelineState?, id: Int = 1, committed: Date? = nil) -> WatchItem {
    let key = MRKey(project: "a/b", iid: iid)
    return WatchItem(
        key: .mergeRequest(key), title: "MR \(iid)", url: key.url, role: role, projectName: "b",
        lastCommitAt: committed, startedBy: nil,
        pipeline: state.map { Pipeline(id: id, state: $0, startedAt: nil, stages: [], runningJobs: [], failedJobs: []) }
    )
}

func branch(_ name: String, _ state: PipelineState?, id: Int = 1, by user: String? = "jane") -> WatchItem {
    let key = BranchKey(project: "a/b", branch: name)
    return WatchItem(
        key: .branch(key), title: name, url: key.pipelinesURL, role: .watched, projectName: "b",
        lastCommitAt: nil, startedBy: user,
        pipeline: state.map { Pipeline(id: id, state: $0, startedAt: nil, stages: [], runningJobs: [], failedJobs: []) }
    )
}

func snapshot(_ items: WatchItem...) -> Snapshot {
    Snapshot(items: items, watchErrors: [:], closedWatched: [])
}

@Test func indicatorIsWorstStateOfOwnItems() {
    #expect(snapshot(mr(1, .authored, .passed), mr(2, .watched, .failed)).indicator() == .failed)
    #expect(snapshot(mr(1, .authored, .running), branch("main", .blocked)).indicator() == .blocked)
    #expect(snapshot(mr(1, .authored, .passed), mr(2, .authored, .running)).indicator() == .running)
    #expect(snapshot(mr(1, .authored, .passed)).indicator() == .passed)
}

@Test func indicatorIgnoresReviewerAndCanceledPipelines() {
    #expect(snapshot(mr(1, .reviewing, .failed)).indicator() == nil)
    #expect(snapshot(mr(1, .authored, .canceled), mr(2, .authored, nil)).indicator() == nil)
}

@Test func indicatorSkipsHiddenItems() {
    let all = snapshot(mr(1, .authored, .failed), mr(2, .authored, .passed))
    #expect(all.indicator(hiding: [.mergeRequest(MRKey(project: "a/b", iid: 1))]) == .passed)
}

@Test func anyRunningCountsEveryRole() {
    #expect(snapshot(mr(1, .reviewing, .running)).anyRunning)
    #expect(!snapshot(mr(1, .authored, .passed)).anyRunning)
}

@Test func knownKeysCoverItemsAndWatchErrors() {
    let missing = ItemKey.branch(BranchKey(project: "x/y", branch: "main"))
    let current = Snapshot(items: [mr(1, .authored, nil)], watchErrors: [missing: "gone"], closedWatched: [])
    #expect(current.knownKeys == [.mergeRequest(MRKey(project: "a/b", iid: 1)), missing])
}

@Test func manualStagesAreTheBlockedStages() {
    let pipeline = Pipeline(
        id: 1, state: .blocked, startedAt: nil,
        stages: [Stage(name: "test", state: .passed), Stage(name: "e2e-regression", state: .blocked),
                 Stage(name: "maintenance", state: .blocked)],
        runningJobs: [], failedJobs: []
    )
    #expect(pipeline.manualStages == ["e2e-regression", "maintenance"])
}
