import Foundation

/// The only way the app reaches GitLab. `GlabTransport` runs glab on the Mac.
/// An iOS app adds a transport that uses URLSession and a token.
public protocol Transport: Sendable {
    func graphQL(_ query: String) async throws -> Data
    func retryJob(project: String, jobID: Int) async throws
    func playJob(project: String, jobID: Int) async throws
    func retryPipeline(project: String, pipelineID: Int) async throws
}
