import Foundation

/// One watch request and its result. A failed request fails only the rows of its keys.
public struct WatchBatch: Sendable {
    public let keys: [ItemKey]
    public let response: Result<Data, any Error>

    public init(keys: [ItemKey], response: Result<Data, any Error>) {
        self.keys = keys
        self.response = response
    }
}

public enum MainQuery {
    static let pipeFragment = """
    fragment Pipe on Pipeline {
      id status startedAt
      stages { nodes { name status } }
      jobs(statuses: [RUNNING, FAILED], retried: false) { nodes { name status } }
    }
    """

    static let mrFragment = """
    fragment MR on MergeRequest {
      iid title webUrl state project { fullPath name }
      commits(first: 1) { nodes { committedDate } }
      headPipeline { ...Pipe }
    }
    """

    static let notFound = "Not found, or you have no access"

    /// GitLab rejects a query with a complexity above 250. The two lists use most of that, and
    /// each watch alias costs about 30 more, so the watches go in requests of their own.
    static let batchSize = 4

    /// The authored list and the reviewer list.
    public static func buildLists() -> String {
        """
        \(pipeFragment)
        \(mrFragment)
        query {
          currentUser {
            authoredMergeRequests(state: opened, first: 50) { nodes { ...MR } }
            reviewRequestedMergeRequests(state: opened, first: 50) { nodes { ...MR } }
          }
        }
        """
    }

    /// One alias `wN` per watched item, for one batch from `batches(_:)`.
    public static func buildWatches(_ keys: [ItemKey]) -> String {
        let aliases = keys.enumerated().map { index, key in
            switch key {
            case .mergeRequest(let mr):
                "w\(index): project(fullPath: \(graphQLString(mr.project))) { mergeRequest(iid: \"\(mr.iid)\") { ...MR } }"
            case .branch(let branch):
                "w\(index): project(fullPath: \(graphQLString(branch.project))) { name pipelines(ref: \(graphQLString(branch.branch)), first: 1) { nodes { ...Pipe user { username } commit { committedDate } } } }"
            }
        }
        // GitLab rejects a query that defines a fragment it does not use.
        let needsMR = keys.contains { if case .mergeRequest = $0 { true } else { false } }
        return """
        \(pipeFragment)
        \(needsMR ? mrFragment : "")
        query {
          \(aliases.joined(separator: "\n  "))
        }
        """
    }

    public static func batches(_ keys: [ItemKey]) -> [[ItemKey]] {
        stride(from: 0, to: keys.count, by: batchSize).map { Array(keys[$0..<min($0 + batchSize, keys.count)]) }
    }

    public static func decode(lists: Data, batches: [WatchBatch]) throws -> Snapshot {
        let response = try makeDecoder().decode(GraphQLResponse<ListsData>.self, from: lists)
        guard let body = response.data else {
            throw DecodeError.noData(response.errors?.map(\.message) ?? [])
        }

        var byKey: [ItemKey: WatchItem] = [:]
        func add(_ item: WatchItem) {
            if let existing = byKey[item.key], existing.role <= item.role { return }
            byKey[item.key] = item
        }

        for node in body.currentUser.authoredMergeRequests.nodes { try add(node.item(role: .authored)) }
        for node in body.currentUser.reviewRequestedMergeRequests.nodes { try add(node.item(role: .reviewing)) }

        var watchErrors: [ItemKey: String] = [:]
        var closedWatched: [ItemKey] = []
        for batch in batches {
            let aliases: [String: WatchedProject?]
            do {
                aliases = try decodeAliases(batch.response.get())
            } catch {
                for key in batch.keys { watchErrors[key] = error.localizedDescription }
                continue
            }
            for (index, key) in batch.keys.enumerated() {
                // GitLab answers null, with no error, for a project or MR that is missing or hidden from you.
                let project = aliases["w\(index)"] ?? nil
                do {
                    switch key {
                    case .mergeRequest:
                        guard let node = project?.mergeRequest else {
                            watchErrors[key] = notFound
                            continue
                        }
                        guard node.state == "opened" else {
                            closedWatched.append(key)
                            continue
                        }
                        try add(node.item(role: .watched))
                    case .branch(let branch):
                        guard let project, let name = project.name else {
                            watchErrors[key] = notFound
                            continue
                        }
                        guard let node = project.pipelines?.nodes.first else {
                            watchErrors[key] = "No pipelines on this branch"
                            continue
                        }
                        try add(WatchItem(
                            key: key, title: branch.branch, url: branch.pipelinesURL, role: .watched,
                            projectName: name, lastCommitAt: node.commit?.committedDate,
                            startedBy: node.user?.username, pipeline: node.pipeline()
                        ))
                    }
                } catch {
                    watchErrors[key] = error.localizedDescription
                }
            }
        }

        let sorted = byKey.values.sorted { $0.role != $1.role ? $0.role < $1.role : recentFirst($0, $1) }
        return Snapshot(items: sorted, watchErrors: watchErrors, closedWatched: closedWatched)
    }

    static func decodeAliases(_ data: Data) throws -> [String: WatchedProject?] {
        let response = try makeDecoder().decode(GraphQLResponse<WatchData>.self, from: data)
        guard let body = response.data else {
            throw DecodeError.noData(response.errors?.map(\.message) ?? [])
        }
        return body.aliases
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

struct ListsData: Decodable {
    let currentUser: CurrentUser
}

struct WatchData: Decodable {
    let aliases: [String: WatchedProject?]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var aliases: [String: WatchedProject?] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("w") {
            aliases[key.stringValue] = try container.decodeIfPresent(WatchedProject.self, forKey: key)
        }
        self.aliases = aliases
    }
}

struct CurrentUser: Decodable {
    let authoredMergeRequests: Connection<MRNode>
    let reviewRequestedMergeRequests: Connection<MRNode>
}

/// An MR alias reads `mergeRequest`. A branch alias reads `name` and `pipelines`.
struct WatchedProject: Decodable {
    let mergeRequest: MRNode?
    let name: String?
    let pipelines: Connection<PipelineNode>?
}

struct ProjectRef: Decodable {
    let fullPath: String
    let name: String
}

struct StatusNode: Decodable {
    let name: String
    let status: String
}

struct CommitDate: Decodable {
    let committedDate: Date
}

struct UserRef: Decodable {
    let username: String
}

struct MRNode: Decodable {
    let iid: String
    let title: String
    let webUrl: URL
    let state: String
    let project: ProjectRef
    let commits: Connection<CommitDate>?
    let headPipeline: PipelineNode?

    func item(role: Role) throws -> WatchItem {
        guard let iid = Int(iid) else { throw DecodeError.badID(iid) }
        return WatchItem(
            key: .mergeRequest(MRKey(project: project.fullPath, iid: iid)),
            title: title,
            url: webUrl,
            role: role,
            projectName: project.name,
            lastCommitAt: commits?.nodes.first?.committedDate,
            startedBy: nil,
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
    // Only branch aliases read these two.
    let user: UserRef?
    let commit: CommitDate?

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
