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

func mr(_ iid: Int, _ role: Role, _ state: PipelineState?, id: Int = 1) -> MergeRequest {
    MergeRequest(
        key: MRKey(project: "a/b", iid: iid),
        title: "MR \(iid)",
        url: MRKey(project: "a/b", iid: iid).url,
        role: role,
        pipeline: state.map {
            Pipeline(id: id, state: $0, startedAt: nil, stages: [], runningJobs: [], failedJobs: [])
        }
    )
}

func snapshot(_ mergeRequests: MergeRequest...) -> Snapshot {
    Snapshot(mergeRequests: mergeRequests, watchErrors: [:], closedWatched: [])
}

@Test func indicatorIsWorstStateOfOwnMergeRequests() {
    #expect(snapshot(mr(1, .authored, .passed), mr(2, .watched, .failed)).indicator == .failed)
    #expect(snapshot(mr(1, .authored, .running), mr(2, .authored, .blocked)).indicator == .blocked)
    #expect(snapshot(mr(1, .authored, .passed), mr(2, .authored, .running)).indicator == .running)
    #expect(snapshot(mr(1, .authored, .passed)).indicator == .passed)
}

@Test func indicatorIgnoresReviewerAndCanceledPipelines() {
    #expect(snapshot(mr(1, .reviewing, .failed)).indicator == nil)
    #expect(snapshot(mr(1, .authored, .canceled), mr(2, .authored, nil)).indicator == nil)
}

@Test func anyRunningCountsEveryRole() {
    #expect(snapshot(mr(1, .reviewing, .running)).anyRunning)
    #expect(!snapshot(mr(1, .authored, .passed)).anyRunning)
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
