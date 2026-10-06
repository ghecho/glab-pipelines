import Foundation
import Testing
@testable import PipelineCore

@Test func buildsQueryForOneMergeRequest() {
    let query = PipelineQuery.build(MRKey(project: "a/b", iid: 123))
    #expect(query.contains(#"project(fullPath: "a/b")"#))
    #expect(query.contains(#"mergeRequest(iid: "123")"#))
    #expect(query.contains("jobs(first: 100, retried: false)"))
}

@Test func groupsJobsByStageInStageOrder() throws {
    let data = Data("""
    {"data": {"project": {"mergeRequest": {"headPipeline": {
      "stages": {"nodes": [{"name": "test", "status": "failed"}, {"name": "maintenance", "status": "manual"}]},
      "jobs": {"nodes": [
        {"id": "gid://gitlab/Ci::Build/3", "name": "rollback:review", "status": "MANUAL", "duration": null,
         "retryable": false, "playable": true, "allowFailure": true, "stage": {"name": "maintenance"}},
        {"id": "gid://gitlab/Ci::Build/2", "name": "test:unit 2/4", "status": "FAILED", "duration": 312,
         "retryable": true, "playable": false, "allowFailure": false, "stage": {"name": "test"}},
        {"id": "gid://gitlab/Ci::Build/1", "name": "test:unit 1/4", "status": "SUCCESS", "duration": 300,
         "retryable": true, "playable": false, "allowFailure": false, "stage": {"name": "test"}}
      ]}}}}}}
    """.utf8)
    let detail = try #require(try PipelineQuery.decode(data))
    #expect(detail.stages.map(\.name) == ["test", "maintenance"])
    #expect(detail.stages[0].state == .failed)
    #expect(detail.stages[0].jobs.map(\.name) == ["test:unit 1/4", "test:unit 2/4"])
    #expect(detail.stages[1].jobs == [
        Job(id: 3, name: "rollback:review", state: .blocked, duration: nil,
            retryable: false, playable: true, allowFailure: true),
    ])
}

@Test func mergeRequestWithoutPipelineDecodesToNil() throws {
    let data = Data(#"{"data": {"project": {"mergeRequest": {"headPipeline": null}}}}"#.utf8)
    #expect(try PipelineQuery.decode(data) == nil)
}

@Test func missingMergeRequestFailsTheDecode() {
    let data = Data(#"{"data": {"project": null}}"#.utf8)
    #expect(throws: DecodeError.noData(["Not found, or you have no access"])) { try PipelineQuery.decode(data) }
}
