import Foundation

public struct MRKey: Hashable, Sendable {
    public let project: String
    public let iid: Int

    public init(project: String, iid: Int) {
        self.project = project
        self.iid = iid
    }

    /// Reads `https://gitlab.com/<project>/-/merge_requests/<iid>`. A trailing path, query or
    /// fragment, as in a link copied from the Changes tab or from a comment, is ignored.
    public init?(url: URL) {
        guard url.host() == "gitlab.com" else { return nil }
        let parts = url.path().components(separatedBy: "/-/merge_requests/")
        guard parts.count == 2,
              parts[0].count > 1,
              let iid = parts[1].split(separator: "/").first.flatMap({ Int($0) })
        else { return nil }
        self.init(project: String(parts[0].dropFirst()), iid: iid)
    }

    public var url: URL {
        URL(string: "https://gitlab.com/\(project)/-/merge_requests/\(iid)")!
    }
}

public struct BranchKey: Hashable, Sendable {
    public let project: String
    public let branch: String

    public init(project: String, branch: String) {
        self.project = project
        self.branch = branch
    }

    /// Reads `https://gitlab.com/<project>/-/tree/<branch>` or `/-/commits/<branch>`. Everything
    /// after the marker is the branch name, so a name with a slash works.
    public init?(url: URL) {
        guard url.host() == "gitlab.com" else { return nil }
        let path = url.path(percentEncoded: false)
        guard let marker = ["/-/tree/", "/-/commits/"].first(where: { path.contains($0) }) else { return nil }
        let parts = path.components(separatedBy: marker)
        guard parts.count == 2, parts[0].count > 1 else { return nil }
        var branch = parts[1]
        if branch.hasSuffix("/") { branch.removeLast() }
        guard !branch.isEmpty else { return nil }
        self.init(project: String(parts[0].dropFirst()), branch: branch)
    }

    /// The form the watch list stores.
    public var url: URL {
        URL(string: "https://gitlab.com/\(project)/-/tree/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!
    }

    /// The project's pipelines page, filtered to this branch.
    public var pipelinesURL: URL {
        var components = URLComponents(string: "https://gitlab.com/\(project)/-/pipelines")!
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        return components.url!
    }
}

public enum ItemKey: Hashable, Sendable {
    case mergeRequest(MRKey)
    case branch(BranchKey)

    /// Reads a stored watch: an MR URL or a branch URL.
    public init?(url: URL) {
        if let key = MRKey(url: url) {
            self = .mergeRequest(key)
        } else if let key = BranchKey(url: url) {
            self = .branch(key)
        } else {
            return nil
        }
    }

    public var project: String {
        switch self {
        case .mergeRequest(let key): key.project
        case .branch(let key): key.project
        }
    }

    public var url: URL {
        switch self {
        case .mergeRequest(let key): key.url
        case .branch(let key): key.url
        }
    }
}

/// What the Watch field accepts.
public enum WatchInput: Equatable, Sendable {
    case item(ItemKey)
    /// A pipeline URL. The app asks GitLab once for the branch of the pipeline.
    case pipeline(project: String, id: Int)

    public init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        if let key = ItemKey(url: url) {
            self = .item(key)
            return
        }
        let parts = url.path(percentEncoded: false).components(separatedBy: "/-/pipelines/")
        guard url.host() == "gitlab.com", parts.count == 2, parts[0].count > 1,
              let id = parts[1].split(separator: "/").first.flatMap({ Int($0) })
        else { return nil }
        self = .pipeline(project: String(parts[0].dropFirst()), id: id)
    }
}

/// The order is the precedence when one MR is in more than one list.
public enum Role: Int, Comparable, Sendable {
    case authored, watched, reviewing

    public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PipelineState: String, Sendable, CaseIterable {
    case running, passed, failed, blocked, canceled

    /// GitLab spells pipeline and job statuses in upper case and stage statuses in lower case.
    public init(gitlab status: String) throws {
        switch status.uppercased() {
        case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "WAITING_FOR_CALLBACK",
             "PENDING", "RUNNING", "SCHEDULED", "CANCELING":
            self = .running
        case "SUCCESS": self = .passed
        case "FAILED": self = .failed
        case "MANUAL": self = .blocked
        case "CANCELED", "SKIPPED": self = .canceled
        default: throw DecodeError.unknownStatus(status)
        }
    }
}

public struct Stage: Equatable, Sendable {
    public let name: String
    public let state: PipelineState

    public init(name: String, state: PipelineState) {
        self.name = name
        self.state = state
    }
}

public struct Pipeline: Equatable, Sendable {
    public let id: Int
    public let state: PipelineState
    public let startedAt: Date?
    public let stages: [Stage]
    public let runningJobs: [String]
    public let failedJobs: [String]

    public init(id: Int, state: PipelineState, startedAt: Date?, stages: [Stage],
                runningJobs: [String], failedJobs: [String]) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.stages = stages
        self.runningJobs = runningJobs
        self.failedJobs = failedJobs
    }

    public var manualStages: [String] {
        stages.filter { $0.state == .blocked }.map(\.name)
    }
}

/// An MR, or the latest pipeline of a watched branch.
public struct WatchItem: Equatable, Sendable, Identifiable {
    public let key: ItemKey
    /// The MR title, or the branch name.
    public let title: String
    /// The MR page, or the branch's pipelines page.
    public let url: URL
    public let role: Role
    public let projectName: String
    public let lastCommitAt: Date?
    /// Who started the pipeline. Only branch items carry it, because a branch pipeline can be anyone's.
    public let startedBy: String?
    public let pipeline: Pipeline?

    public init(key: ItemKey, title: String, url: URL, role: Role, projectName: String,
                lastCommitAt: Date?, startedBy: String?, pipeline: Pipeline?) {
        self.key = key
        self.title = title
        self.url = url
        self.role = role
        self.projectName = projectName
        self.lastCommitAt = lastCommitAt
        self.startedBy = startedBy
        self.pipeline = pipeline
    }

    public var id: ItemKey { key }
}

/// Newest last commit first. An item with no date goes last. Ties sort by title, so the order is stable.
func recentFirst(_ a: WatchItem, _ b: WatchItem) -> Bool {
    switch (a.lastCommitAt, b.lastCommitAt) {
    case let (x?, y?) where x != y: x > y
    case (.some, nil): true
    case (nil, .some): false
    default: a.title < b.title
    }
}

public struct Snapshot: Equatable, Sendable {
    public let items: [WatchItem]
    /// Watched items that GitLab returned no data for.
    public let watchErrors: [ItemKey: String]
    /// Watched MRs that are merged or closed.
    public let closedWatched: [ItemKey]

    public init(items: [WatchItem], watchErrors: [ItemKey: String], closedWatched: [ItemKey]) {
        self.items = items
        self.watchErrors = watchErrors
        self.closedWatched = closedWatched
    }

    public func item(for key: ItemKey) -> WatchItem? {
        items.first { $0.key == key }
    }

    public var anyRunning: Bool {
        items.contains { $0.pipeline?.state == .running }
    }

    /// The worst state among authored and watched items that are not hidden. Reviewer MRs do not count.
    public func indicator(hiding hidden: Set<ItemKey> = []) -> PipelineState? {
        let states = Set(items.filter { $0.role != .reviewing && !hidden.contains($0.key) }.compactMap(\.pipeline?.state))
        return [PipelineState.failed, .blocked, .running, .passed].first(where: states.contains)
    }

    /// Every key this poll knows about. Pins and hidden keys outside this set belong to merged or closed MRs.
    public var knownKeys: Set<ItemKey> {
        Set(items.map(\.key)).union(watchErrors.keys)
    }
}

public enum DecodeError: Error, Equatable, LocalizedError {
    case unknownStatus(String)
    case badID(String)
    case noData([String])

    public var errorDescription: String? {
        switch self {
        case .unknownStatus(let status): "GitLab sent an unknown status: \(status)"
        case .badID(let id): "GitLab sent an id that is not a number: \(id)"
        case .noData(let messages): messages.isEmpty ? "GitLab sent no data" : messages.joined(separator: "\n")
        }
    }
}

/// GraphQL ids look like `gid://gitlab/Ci::Pipeline/1234567890`. glab and the REST API take the number.
public func numericID(_ gid: String) throws -> Int {
    guard let id = gid.split(separator: "/").last.flatMap({ Int($0) }) else {
        throw DecodeError.badID(gid)
    }
    return id
}
