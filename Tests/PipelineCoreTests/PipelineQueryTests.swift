import Foundation
import Testing
@testable import PipelineCore

@Test func buildsQueryForOnePipeline() {
    let query = PipelineQuery.build(project: "a/b", pipelineID: 42)
    #expect(query.contains(#"project(fullPath: "a/b")"#))
    #expect(query.contains(#"pipeline(id: "gid://gitlab/Ci::Pipeline/42")"#))
    #expect(query.contains("jobs(first: 100, retried: false)"))
}

@Test func groupsJobsByStageInStageOrder() throws {
    let data = Data("""
    {"data": {"project": {"pipeline": {
      "stages": {"nodes": [{"name": "test", "status": "failed"}, {"name": "maintenance", "status": "manual"}]},
      "jobs": {"nodes": [
        {"id": "gid://gitlab/Ci::Build/3", "name": "rollback:review", "status": "MANUAL", "duration": null, "startedAt": null,
         "retryable": false, "playable": true, "allowFailure": true, "stage": {"name": "maintenance"}},
        {"id": "gid://gitlab/Ci::Build/2", "name": "test:unit 2/4", "status": "FAILED", "duration": 312, "startedAt": "2026-10-12T09:00:00Z",
         "retryable": true, "playable": false, "allowFailure": false, "stage": {"name": "test"}},
        {"id": "gid://gitlab/Ci::Build/1", "name": "test:unit 1/4", "status": "SUCCESS", "duration": 300, "startedAt": "2026-10-12T08:59:00Z",
         "retryable": true, "playable": false, "allowFailure": false, "stage": {"name": "test"}}
      ]}}}}}
    """.utf8)
    let detail = try PipelineQuery.decode(data)
    #expect(detail.stages.map(\.name) == ["test", "maintenance"])
    #expect(detail.stages[0].state == .failed)
    #expect(detail.stages[0].jobs.map(\.name) == ["test:unit 1/4", "test:unit 2/4"])
    #expect(detail.stages[0].jobs[1].startedAt == ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z"))
    #expect(detail.stages[1].jobs == [
        Job(id: 3, name: "rollback:review", state: .blocked, duration: nil, startedAt: nil,
            retryable: false, playable: true, allowFailure: true),
    ])
}

@Test(arguments: [#"{"data": {"project": {"pipeline": null}}}"#, #"{"data": {"project": null}}"#])
func missingPipelineFailsTheDecode(text: String) {
    #expect(throws: DecodeError.noData(["Not found, or you have no access"])) { try PipelineQuery.decode(Data(text.utf8)) }
}

@Test func buildsBranchLookup() {
    let query = PipelineQuery.buildBranchLookup(project: "a/b", pipelineID: 42)
    #expect(query.contains(#"project(fullPath: "a/b")"#))
    #expect(query.contains(#"pipeline(id: "gid://gitlab/Ci::Pipeline/42") { ref }"#))
}

@Test func decodesBranchLookup() throws {
    let data = Data(#"{"data": {"project": {"pipeline": {"ref": "feature/fix-login"}}}}"#.utf8)
    #expect(try PipelineQuery.decodeBranch(data) == "feature/fix-login")
}

@Test func branchLookupOfMissingPipelineFails() {
    let data = Data(#"{"data": {"project": {"pipeline": null}}}"#.utf8)
    #expect(throws: DecodeError.noData(["Not found, or you have no access"])) { try PipelineQuery.decodeBranch(data) }
}
