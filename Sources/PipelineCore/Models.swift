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

public struct MergeRequest: Equatable, Sendable, Identifiable {
    public let key: MRKey
    public let title: String
    public let url: URL
    public let role: Role
    public let pipeline: Pipeline?

    public init(key: MRKey, title: String, url: URL, role: Role, pipeline: Pipeline?) {
        self.key = key
        self.title = title
        self.url = url
        self.role = role
        self.pipeline = pipeline
    }

    public var id: MRKey { key }
}

public struct Snapshot: Equatable, Sendable {
    public let mergeRequests: [MergeRequest]
    /// Watched MRs that GitLab returned no data for.
    public let watchErrors: [MRKey: String]
    /// Watched MRs that are merged or closed.
    public let closedWatched: [MRKey]

    public init(mergeRequests: [MergeRequest], watchErrors: [MRKey: String], closedWatched: [MRKey]) {
        self.mergeRequests = mergeRequests
        self.watchErrors = watchErrors
        self.closedWatched = closedWatched
    }

    public func mergeRequest(for key: MRKey) -> MergeRequest? {
        mergeRequests.first { $0.key == key }
    }

    public var anyRunning: Bool {
        mergeRequests.contains { $0.pipeline?.state == .running }
    }

    /// The worst state among authored and watched MRs. Reviewer MRs do not count.
    public var indicator: PipelineState? {
        let states = Set(mergeRequests.filter { $0.role != .reviewing }.compactMap(\.pipeline?.state))
        return [PipelineState.failed, .blocked, .running, .passed].first(where: states.contains)
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
