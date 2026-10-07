import Foundation
import Testing
@testable import PipelineCore

func mrNode(_ iid: Int, status: String? = "SUCCESS", state: String = "opened", project: String = "a/b",
            committed: String? = "2026-10-07T12:45:57+00:00") -> String {
    let pipeline = status.map {
        """
        {"id": "gid://gitlab/Ci::Pipeline/\(iid)00", "status": "\($0)", "startedAt": "2026-10-06T13:04:32Z",
         "stages": {"nodes": [{"name": "test", "status": "success"}, {"name": "e2e-regression", "status": "manual"}]},
         "jobs": {"nodes": [{"name": "lint", "status": "FAILED"}, {"name": "e2e 1/3", "status": "RUNNING"}]}}
        """
    } ?? "null"
    let commits = committed.map { #"[{"committedDate": "\#($0)"}]"# } ?? "[]"
    return """
    {"iid": "\(iid)", "title": "MR \(iid)", "webUrl": "https://gitlab.com/\(project)/-/merge_requests/\(iid)",
     "state": "\(state)", "project": {"fullPath": "\(project)", "name": "repo"},
     "commits": {"nodes": \(commits)}, "headPipeline": \(pipeline)}
    """
}

func branchAlias(_ status: String?) -> String {
    let nodes = status.map {
        #"[{"id": "gid://gitlab/Ci::Pipeline/77", "status": "\#($0)", "startedAt": null, "stages": {"nodes": []}, "jobs": {"nodes": []}, "user": {"username": "jane"}, "commit": {"committedDate": "2026-10-07T15:14:18Z"}}]"#
    } ?? "[]"
    return #"{"name": "app", "pipelines": {"nodes": \#(nodes)}}"#
}

func response(authored: [String] = [], reviewing: [String] = [], aliases: [String: String] = [:]) -> Data {
    let extra = aliases.map { ", \"\($0.key)\": \($0.value)" }.joined()
    return Data("""
    {"data": {"currentUser": {
      "authoredMergeRequests": {"nodes": [\(authored.joined(separator: ","))]},
      "reviewRequestedMergeRequests": {"nodes": [\(reviewing.joined(separator: ","))]}}\(extra)}}
    """.utf8)
}

let mainBranch = ItemKey.branch(BranchKey(project: "a/b", branch: "main"))

/// One JSON body serves as the lists response and as a single watch batch, as these tests write it.
func decodeAll(_ data: Data, _ watched: [ItemKey]) throws -> Snapshot {
    try MainQuery.decode(lists: data, batches: watched.isEmpty ? [] : [WatchBatch(keys: watched, response: .success(data))])
}

@Test func listsQueryHasNoWatchAliases() {
    let query = MainQuery.buildLists()
    #expect(query.contains("authoredMergeRequests(state: opened, first: 50)"))
    #expect(query.contains("reviewRequestedMergeRequests(state: opened, first: 50)"))
    #expect(query.contains("commits(first: 1) { nodes { committedDate } }"))
    #expect(!query.contains("w0:"))
}

@Test func buildsOneAliasPerWatchedItem() {
    let query = MainQuery.buildWatches([
        .mergeRequest(MRKey(project: "a/b", iid: 1)),
        .branch(BranchKey(project: "c/\"d", branch: "feature/x")),
    ])
    #expect(query.contains(#"w0: project(fullPath: "a/b") { mergeRequest(iid: "1") { ...MR } }"#))
    #expect(query.contains(#"w1: project(fullPath: "c/\"d") { name pipelines(ref: "feature/x", first: 1)"#))
    #expect(query.contains("retried: false"))
    #expect(!query.contains("currentUser"))
}

@Test func watchesQueryLeavesOutTheUnusedMRFragment() {
    #expect(!MainQuery.buildWatches([mainBranch]).contains("fragment MR"))
    #expect(MainQuery.buildWatches([.mergeRequest(MRKey(project: "a/b", iid: 1))]).contains("fragment MR"))
}

@Test func splitsWatchesIntoBatchesOfFour() {
    let keys = (1...9).map { ItemKey.mergeRequest(MRKey(project: "a/b", iid: $0)) }
    #expect(MainQuery.batches(keys).map(\.count) == [4, 4, 1])
    #expect(MainQuery.batches([]).isEmpty)
}

@Test func failedBatchBecomesRowErrors() throws {
    let other = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 2))
    let snapshot = try MainQuery.decode(lists: response(authored: [mrNode(1)]), batches: [
        WatchBatch(keys: [mainBranch], response: .failure(GlabError.failed("Query has complexity of 258"))),
        WatchBatch(keys: [other], response: .success(response(aliases: ["w0": #"{"mergeRequest": \#(mrNode(2))}"#]))),
    ])
    #expect(snapshot.items.map(\.title) == ["MR 1", "MR 2"])
    #expect(snapshot.watchErrors == [mainBranch: "Query has complexity of 258"])
}

@Test func unknownStatusInAWatchFailsOnlyThatRow() throws {
    let bad = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 3))
    let data = response(aliases: ["w0": #"{"mergeRequest": \#(mrNode(3, status: "WOBBLING"))}"#, "w1": branchAlias("SUCCESS")])
    let snapshot = try decodeAll(data, [bad, mainBranch])
    #expect(snapshot.items.map(\.title) == ["main"])
    #expect(snapshot.watchErrors == [bad: "GitLab sent an unknown status: WOBBLING"])
}

@Test func decodesMergeRequestFields() throws {
    let snapshot = try decodeAll(response(authored: [mrNode(123, status: "MANUAL")]), [])
    let item = try #require(snapshot.items.first)
    #expect(item.key == .mergeRequest(MRKey(project: "a/b", iid: 123)))
    #expect(item.projectName == "repo")
    #expect(item.lastCommitAt == at("2026-10-07T12:45:57Z"))
    #expect(item.startedBy == nil)
    let pipeline = try #require(item.pipeline)
    #expect(pipeline.id == 12300)
    #expect(pipeline.state == .blocked)
    #expect(pipeline.manualStages == ["e2e-regression"])
    #expect(pipeline.failedJobs == ["lint"])
    #expect(pipeline.runningJobs == ["e2e 1/3"])
}

@Test func decodesMergeRequestWithoutCommits() throws {
    let snapshot = try decodeAll(response(authored: [mrNode(1, committed: nil)]), [])
    #expect(snapshot.items.first?.lastCommitAt == nil)
}

@Test func decodesMergeRequestWithoutPipeline() throws {
    let snapshot = try decodeAll(response(authored: [mrNode(1, status: nil)]), [])
    #expect(snapshot.items.first?.pipeline == nil)
}

@Test func decodesSkippedPipelineWithoutStages() throws {
    let node = """
    {"iid": "456", "title": "MR", "webUrl": "https://gitlab.com/a/b/-/merge_requests/456", "state": "opened",
     "project": {"fullPath": "a/b", "name": "b"}, "commits": {"nodes": []},
     "headPipeline": {"id": "gid://gitlab/Ci::Pipeline/5", "status": "SKIPPED", "startedAt": null,
                      "stages": {"nodes": []}, "jobs": {"nodes": []}}}
    """
    let pipeline = try #require(try decodeAll(response(authored: [node]), []).items.first?.pipeline)
    #expect(pipeline.state == .canceled)
    #expect(pipeline.startedAt == nil)
    #expect(pipeline.stages.isEmpty)
}

@Test func authoredWinsOverReviewing() throws {
    let snapshot = try decodeAll(response(authored: [mrNode(1)], reviewing: [mrNode(1), mrNode(2)]), [])
    #expect(snapshot.items.map(\.title) == ["MR 1", "MR 2"])
    #expect(snapshot.items.map(\.role) == [.authored, .reviewing])
}

@Test func watchedWinsOverReviewing() throws {
    let key = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 2))
    let data = response(reviewing: [mrNode(2)], aliases: ["w0": #"{"mergeRequest": \#(mrNode(2))}"#])
    #expect(try decodeAll(data, [key]).items.map(\.role) == [.watched])
}

@Test func sortsByRoleThenNewestCommit() throws {
    let data = response(
        authored: [mrNode(1, committed: "2026-10-07T09:00:00Z"), mrNode(3, committed: "2026-10-07T10:00:00Z")],
        reviewing: [mrNode(2)]
    )
    #expect(try decodeAll(data, []).items.map(\.title) == ["MR 3", "MR 1", "MR 2"])
}

@Test func missingWatchedMergeRequestIsARowError() throws {
    let gone = ItemKey.mergeRequest(MRKey(project: "x/gone", iid: 1))
    let noMR = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 999))
    let data = response(authored: [mrNode(5)], aliases: ["w0": "null", "w1": #"{"mergeRequest": null}"#])
    let snapshot = try decodeAll(data, [gone, noMR])
    #expect(snapshot.items.map(\.title) == ["MR 5"])
    #expect(snapshot.watchErrors == [gone: "Not found, or you have no access", noMR: "Not found, or you have no access"])
}

@Test func closedWatchedMergeRequestIsReported() throws {
    let key = ItemKey.mergeRequest(MRKey(project: "a/b", iid: 4))
    let data = response(aliases: ["w0": #"{"mergeRequest": \#(mrNode(4, state: "merged"))}"#])
    let snapshot = try decodeAll(data, [key])
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.closedWatched == [key])
}

@Test func decodesBranchWatch() throws {
    let snapshot = try decodeAll(response(aliases: ["w0": branchAlias("RUNNING")]), [mainBranch])
    let item = try #require(snapshot.items.first)
    #expect(item.key == mainBranch)
    #expect(item.title == "main")
    #expect(item.role == .watched)
    #expect(item.projectName == "app")
    #expect(item.startedBy == "jane")
    #expect(item.lastCommitAt == at("2026-10-07T15:14:18Z"))
    #expect(item.url == BranchKey(project: "a/b", branch: "main").pipelinesURL)
    #expect(item.pipeline?.id == 77)
    #expect(item.pipeline?.state == .running)
}

@Test func branchWithoutPipelinesIsARowError() throws {
    let snapshot = try decodeAll(response(aliases: ["w0": branchAlias(nil)]), [mainBranch])
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.watchErrors == [mainBranch: "No pipelines on this branch"])
}

@Test func missingBranchProjectIsARowError() throws {
    let snapshot = try decodeAll(response(aliases: ["w0": "null"]), [mainBranch])
    #expect(snapshot.watchErrors == [mainBranch: "Not found, or you have no access"])
}

@Test func unknownStatusFailsTheDecode() {
    #expect(throws: DecodeError.unknownStatus("WOBBLING")) {
        try decodeAll(response(authored: [mrNode(1, status: "WOBBLING")]), [])
    }
}

@Test func errorsWithoutDataFailTheDecode() {
    let data = Data(#"{"errors": [{"message": "Field 'bogus' doesn't exist on type 'Query'"}]}"#.utf8)
    #expect(throws: DecodeError.noData(["Field 'bogus' doesn't exist on type 'Query'"])) {
        try decodeAll(data, [])
    }
}
