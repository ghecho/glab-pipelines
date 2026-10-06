import Foundation

public enum MainQuery {
    static let fragment = """
    fragment MR on MergeRequest {
      iid title webUrl state project { fullPath }
      headPipeline {
        id status startedAt
        stages { nodes { name status } }
        jobs(statuses: [RUNNING, FAILED], retried: false) { nodes { name status } }
      }
    }
    """

    /// One request for the authored list, the reviewer list and one alias `wN` per watched MR.
    public static func build(watched: [MRKey]) -> String {
        let aliases = watched.enumerated().map { index, key in
            "w\(index): project(fullPath: \(graphQLString(key.project))) { mergeRequest(iid: \"\(key.iid)\") { ...MR } }"
        }
        return """
        \(fragment)
        query {
          currentUser {
            authoredMergeRequests(state: opened, first: 50) { nodes { ...MR } }
            reviewRequestedMergeRequests(state: opened, first: 50) { nodes { ...MR } }
          }
          \(aliases.joined(separator: "\n  "))
        }
        """
    }

    public static func decode(_ data: Data, watched: [MRKey]) throws -> Snapshot {
        let response = try makeDecoder().decode(GraphQLResponse<MainData>.self, from: data)
        guard let body = response.data else {
            throw DecodeError.noData(response.errors?.map(\.message) ?? [])
        }

        var byKey: [MRKey: MergeRequest] = [:]
        func add(_ node: MRNode, as role: Role) throws {
            let mergeRequest = try node.mergeRequest(role: role)
            if let existing = byKey[mergeRequest.key], existing.role <= role { return }
            byKey[mergeRequest.key] = mergeRequest
        }

        for node in body.currentUser.authoredMergeRequests.nodes { try add(node, as: .authored) }
        for node in body.currentUser.reviewRequestedMergeRequests.nodes { try add(node, as: .reviewing) }

        var watchErrors: [MRKey: String] = [:]
        var closedWatched: [MRKey] = []
        for (index, key) in watched.enumerated() {
            // GitLab answers null, with no error, for a project or MR that is missing or hidden from you.
            guard let node = (body.aliases["w\(index)"] ?? nil)?.mergeRequest else {
                watchErrors[key] = "Not found, or you have no access"
                continue
            }
            guard node.state == "opened" else {
                closedWatched.append(key)
                continue
            }
            try add(node, as: .watched)
        }

        let sorted = byKey.values.sorted { ($0.role, -$0.key.iid) < ($1.role, -$1.key.iid) }
        return Snapshot(mergeRequests: sorted, watchErrors: watchErrors, closedWatched: closedWatched)
    }
}

/// A GraphQL string literal. JSON string escaping is valid GraphQL string escaping.
func graphQLString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
}

func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

struct GraphQLResponse<D: Decodable>: Decodable {
    let data: D?
    let errors: [GraphQLMessage]?
}

struct GraphQLMessage: Decodable {
    let message: String
}

struct Connection<T: Decodable>: Decodable {
    let nodes: [T]
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct MainData: Decodable {
    let currentUser: CurrentUser
    let aliases: [String: WatchedProject?]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        currentUser = try container.decode(CurrentUser.self, forKey: AnyKey("currentUser"))
        var aliases: [String: WatchedProject?] = [:]
        for key in container.allKeys where key.stringValue != "currentUser" {
            aliases[key.stringValue] = try container.decodeIfPresent(WatchedProject.self, forKey: key)
        }
        self.aliases = aliases
    }
}

struct CurrentUser: Decodable {
    let authoredMergeRequests: Connection<MRNode>
    let reviewRequestedMergeRequests: Connection<MRNode>
}

struct WatchedProject: Decodable {
    let mergeRequest: MRNode?
}

struct ProjectRef: Decodable {
    let fullPath: String
}

struct StatusNode: Decodable {
    let name: String
    let status: String
}

struct MRNode: Decodable {
    let iid: String
    let title: String
    let webUrl: URL
    let state: String
    let project: ProjectRef
    let headPipeline: PipelineNode?

    func mergeRequest(role: Role) throws -> MergeRequest {
        guard let iid = Int(iid) else { throw DecodeError.badID(iid) }
        return MergeRequest(
            key: MRKey(project: project.fullPath, iid: iid),
            title: title,
            url: webUrl,
            role: role,
            pipeline: try headPipeline?.pipeline()
        )
    }
}

struct PipelineNode: Decodable {
    let id: String
    let status: String
    let startedAt: Date?
    // Both connections are nullable in the GitLab schema.
    let stages: Connection<StatusNode>?
    let jobs: Connection<StatusNode>?

    func pipeline() throws -> Pipeline {
        let jobs = jobs?.nodes ?? []
        return Pipeline(
            id: try numericID(id),
            state: try PipelineState(gitlab: status),
            startedAt: startedAt,
            stages: try (stages?.nodes ?? []).map { Stage(name: $0.name, state: try PipelineState(gitlab: $0.status)) },
            runningJobs: jobs.filter { $0.status == "RUNNING" }.map(\.name),
            failedJobs: jobs.filter { $0.status == "FAILED" }.map(\.name)
        )
    }
}
