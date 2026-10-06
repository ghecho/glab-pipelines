import Foundation
import Testing
@testable import PipelineCore

func mrNode(_ iid: Int, status: String? = "SUCCESS", state: String = "opened", project: String = "a/b") -> String {
    let pipeline = status.map {
        """
        {"id": "gid://gitlab/Ci::Pipeline/\(iid)00", "status": "\($0)", "startedAt": "2026-10-06T13:04:32Z",
         "stages": {"nodes": [{"name": "test", "status": "success"}, {"name": "e2e-regression", "status": "manual"}]},
         "jobs": {"nodes": [{"name": "lint", "status": "FAILED"}, {"name": "e2e 1/3", "status": "RUNNING"}]}}
        """
    } ?? "null"
    return """
    {"iid": "\(iid)", "title": "MR \(iid)", "webUrl": "https://gitlab.com/\(project)/-/merge_requests/\(iid)",
     "state": "\(state)", "project": {"fullPath": "\(project)"}, "headPipeline": \(pipeline)}
    """
}

func response(authored: [String] = [], reviewing: [String] = [], aliases: [String: String] = [:]) -> Data {
    let extra = aliases.map { ", \"\($0.key)\": \($0.value)" }.joined()
    return Data("""
    {"data": {"currentUser": {
      "authoredMergeRequests": {"nodes": [\(authored.joined(separator: ","))]},
      "reviewRequestedMergeRequests": {"nodes": [\(reviewing.joined(separator: ","))]}}\(extra)}}
    """.utf8)
}

@Test func buildsOneAliasPerWatchedMergeRequest() {
    let query = MainQuery.build(watched: [MRKey(project: "a/b", iid: 1), MRKey(project: "c/\"d", iid: 2)])
    #expect(query.contains("authoredMergeRequests(state: opened, first: 50)"))
    #expect(query.contains("reviewRequestedMergeRequests(state: opened, first: 50)"))
    #expect(query.contains(#"w0: project(fullPath: "a/b") { mergeRequest(iid: "1") { ...MR } }"#))
    #expect(query.contains(#"w1: project(fullPath: "c/\"d") { mergeRequest(iid: "2") { ...MR } }"#))
    #expect(query.contains("retried: false"))
}

@Test func decodesPipelineFields() throws {
    let snapshot = try MainQuery.decode(response(authored: [mrNode(123, status: "MANUAL")]), watched: [])
    let pipeline = try #require(snapshot.mergeRequests.first?.pipeline)
    #expect(pipeline.id == 12300)
    #expect(pipeline.state == .blocked)
    #expect(pipeline.startedAt == ISO8601DateFormatter().date(from: "2026-10-06T13:04:32Z"))
    #expect(pipeline.manualStages == ["e2e-regression"])
    #expect(pipeline.failedJobs == ["lint"])
    #expect(pipeline.runningJobs == ["e2e 1/3"])
}

@Test func decodesSkippedPipelineWithoutStages() throws {
    let node = """
    {"iid": "456", "title": "MR", "webUrl": "https://gitlab.com/a/b/-/merge_requests/456", "state": "opened",
     "project": {"fullPath": "a/b"},
     "headPipeline": {"id": "gid://gitlab/Ci::Pipeline/5", "status": "SKIPPED", "startedAt": null,
                      "stages": {"nodes": []}, "jobs": {"nodes": []}}}
    """
    let pipeline = try #require(try MainQuery.decode(response(authored: [node]), watched: []).mergeRequests.first?.pipeline)
    #expect(pipeline.state == .canceled)
    #expect(pipeline.startedAt == nil)
    #expect(pipeline.stages.isEmpty)
}

@Test func decodesMergeRequestWithoutPipeline() throws {
    let snapshot = try MainQuery.decode(response(authored: [mrNode(1, status: nil)]), watched: [])
    #expect(snapshot.mergeRequests.first?.pipeline == nil)
}

@Test func authoredWinsOverReviewing() throws {
    let snapshot = try MainQuery.decode(response(authored: [mrNode(1)], reviewing: [mrNode(1), mrNode(2)]), watched: [])
    #expect(snapshot.mergeRequests.map(\.key.iid) == [1, 2])
    #expect(snapshot.mergeRequests.map(\.role) == [.authored, .reviewing])
}

@Test func watchedWinsOverReviewing() throws {
    let key = MRKey(project: "a/b", iid: 2)
    let data = response(reviewing: [mrNode(2)], aliases: ["w0": #"{"mergeRequest": \#(mrNode(2))}"#])
    #expect(try MainQuery.decode(data, watched: [key]).mergeRequests.map(\.role) == [.watched])
}

@Test func sortsByRoleThenNewestFirst() throws {
    let snapshot = try MainQuery.decode(response(authored: [mrNode(1), mrNode(3)], reviewing: [mrNode(2)]), watched: [])
    #expect(snapshot.mergeRequests.map(\.key.iid) == [3, 1, 2])
}

@Test func missingWatchedMergeRequestIsARowError() throws {
    let gone = MRKey(project: "x/gone", iid: 1)
    let noMR = MRKey(project: "a/b", iid: 999)
    let data = response(authored: [mrNode(5)], aliases: ["w0": "null", "w1": #"{"mergeRequest": null}"#])
    let snapshot = try MainQuery.decode(data, watched: [gone, noMR])
    #expect(snapshot.mergeRequests.map(\.key.iid) == [5])
    #expect(snapshot.watchErrors == [gone: "Not found, or you have no access", noMR: "Not found, or you have no access"])
}

@Test func closedWatchedMergeRequestIsReported() throws {
    let key = MRKey(project: "a/b", iid: 4)
    let data = response(aliases: ["w0": #"{"mergeRequest": \#(mrNode(4, state: "merged"))}"#])
    let snapshot = try MainQuery.decode(data, watched: [key])
    #expect(snapshot.mergeRequests.isEmpty)
    #expect(snapshot.closedWatched == [key])
}

@Test func unknownStatusFailsTheDecode() {
    #expect(throws: DecodeError.unknownStatus("WOBBLING")) {
        try MainQuery.decode(response(authored: [mrNode(1, status: "WOBBLING")]), watched: [])
    }
}

@Test func errorsWithoutDataFailTheDecode() {
    let data = Data(#"{"errors": [{"message": "Field 'bogus' doesn't exist on type 'Query'"}]}"#.utf8)
    #expect(throws: DecodeError.noData(["Field 'bogus' doesn't exist on type 'Query'"])) {
        try MainQuery.decode(data, watched: [])
    }
}
