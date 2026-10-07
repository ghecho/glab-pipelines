import Foundation

public struct Job: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let state: PipelineState
    public let duration: Int?
    public let retryable: Bool
    public let playable: Bool
    public let allowFailure: Bool

    public init(id: Int, name: String, state: PipelineState, duration: Int?,
                retryable: Bool, playable: Bool, allowFailure: Bool) {
        self.id = id
        self.name = name
        self.state = state
        self.duration = duration
        self.retryable = retryable
        self.playable = playable
        self.allowFailure = allowFailure
    }
}

public struct StageDetail: Equatable, Sendable {
    public let name: String
    public let state: PipelineState
    public let jobs: [Job]
}

public struct PipelineDetail: Equatable, Sendable {
    public let stages: [StageDetail]
}

public enum PipelineQuery {
    /// One pipeline by its id, so MR rows and branch rows use the same query. The jobs field
    /// on a stage rejects `retried`, so the query reads jobs from the pipeline and groups them.
    public static func build(project: String, pipelineID: Int) -> String {
        """
        query {
          project(fullPath: \(graphQLString(project))) {
            pipeline(id: "gid://gitlab/Ci::Pipeline/\(pipelineID)") {
              stages { nodes { name status } }
              jobs(first: 100, retried: false) {
                nodes { id name status duration retryable playable allowFailure stage { name } }
              }
            }
          }
        }
        """
    }

    public static func decode(_ data: Data) throws -> PipelineDetail {
        let response = try makeDecoder().decode(GraphQLResponse<DetailData>.self, from: data)
        guard let body = response.data else {
            throw DecodeError.noData(response.errors?.map(\.message) ?? [])
        }
        guard let pipeline = body.project?.pipeline else {
            throw DecodeError.noData([MainQuery.notFound])
        }

        let jobs = try (pipeline.jobs?.nodes ?? []).map { node in
            (stage: node.stage?.name, job: Job(
                id: try numericID(node.id),
                name: node.name,
                state: try PipelineState(gitlab: node.status),
                duration: node.duration,
                retryable: node.retryable,
                playable: node.playable,
                allowFailure: node.allowFailure
            ))
        }
        let stages = try (pipeline.stages?.nodes ?? []).map { stage in
            StageDetail(
                name: stage.name,
                state: try PipelineState(gitlab: stage.status),
                jobs: jobs.filter { $0.stage == stage.name }.map(\.job).sorted { $0.name < $1.name }
            )
        }
        return PipelineDetail(stages: stages)
    }

    /// For a pasted pipeline URL: the branch the pipeline ran on.
    public static func buildBranchLookup(project: String, pipelineID: Int) -> String {
        "query { project(fullPath: \(graphQLString(project))) { pipeline(id: \"gid://gitlab/Ci::Pipeline/\(pipelineID)\") { ref } } }"
    }

    public static func decodeBranch(_ data: Data) throws -> String {
        let response = try makeDecoder().decode(GraphQLResponse<BranchData>.self, from: data)
        guard let ref = response.data?.project?.pipeline?.ref else {
            throw DecodeError.noData(response.errors?.map(\.message) ?? [MainQuery.notFound])
        }
        return ref
    }
}

struct DetailData: Decodable {
    struct Project: Decodable { let pipeline: PipelineNode? }
    struct PipelineNode: Decodable {
        let stages: Connection<StatusNode>?
        let jobs: Connection<JobNode>?
    }
    struct StageRef: Decodable { let name: String }
    struct JobNode: Decodable {
        let id: String
        let name: String
        let status: String
        let duration: Int?
        let retryable: Bool
        let playable: Bool
        let allowFailure: Bool
        let stage: StageRef?
    }

    let project: Project?
}

struct BranchData: Decodable {
    struct Project: Decodable { let pipeline: PipelineRef? }
    struct PipelineRef: Decodable { let ref: String }

    let project: Project?
}
