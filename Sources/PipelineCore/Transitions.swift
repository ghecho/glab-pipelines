public struct PipelineEvent: Equatable, Sendable {
    public let mergeRequest: MergeRequest
    public let state: PipelineState
    public let text: String
}

public enum Transitions {
    /// `old` is nil for the first snapshot after launch, which only sets the baseline.
    public static func events(from old: Snapshot?, to new: Snapshot) -> [PipelineEvent] {
        guard let old else { return [] }
        return new.mergeRequests.compactMap { mergeRequest in
            guard let pipeline = mergeRequest.pipeline,
                  let text = text(role: mergeRequest.role, pipeline: pipeline)
            else { return nil }
            let before = old.mergeRequest(for: mergeRequest.key)?.pipeline
            if before?.id == pipeline.id && before?.state == pipeline.state { return nil }
            return PipelineEvent(mergeRequest: mergeRequest, state: pipeline.state, text: text)
        }
    }

    /// Nil means no notification. In a project whose last stages are manual, a green pipeline ends in MANUAL, so
    /// `blocked` means "automatic stages done" and counts as a result for reviewers too.
    /// A job that is allowed to fail can fail without failing the pipeline, so the text names it.
    static func text(role: Role, pipeline: Pipeline) -> String? {
        let waiting = "waiting on " + pipeline.manualStages.joined(separator: ", ")
        return switch (pipeline.state, role) {
        case (.passed, _):
            "Passed"
        case (.blocked, _):
            pipeline.failedJobs.isEmpty
                ? "Automatic stages green, " + waiting
                : "Automatic stages done, failed: " + pipeline.failedJobs.joined(separator: ", ") + ", " + waiting
        case (.failed, .authored), (.failed, .watched):
            pipeline.failedJobs.isEmpty ? "Failed" : "Failed: " + pipeline.failedJobs.joined(separator: ", ")
        case (.failed, .reviewing), (.running, _), (.canceled, _):
            nil
        }
    }
}
