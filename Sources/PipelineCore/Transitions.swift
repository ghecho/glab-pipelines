public struct PipelineEvent: Equatable, Sendable {
    public let item: WatchItem
    public let state: PipelineState
    public let text: String
}

public enum Transitions {
    /// `old` is nil for the first snapshot after launch, which only sets the baseline.
    public static func events(from old: Snapshot?, to new: Snapshot) -> [PipelineEvent] {
        guard let old else { return [] }
        return new.items.compactMap { item in
            guard let pipeline = item.pipeline,
                  let text = text(item: item, pipeline: pipeline)
            else { return nil }
            let before = old.item(for: item.key)?.pipeline
            if before?.id == pipeline.id && before?.state == pipeline.state { return nil }
            return PipelineEvent(item: item, state: pipeline.state, text: text)
        }
    }

    /// Nil means no notification. In a project whose last stages are manual, a green pipeline ends in MANUAL, so
    /// `blocked` means "automatic stages done" and counts as a result for reviewers too.
    /// A job that is allowed to fail can fail without failing the pipeline, so the text names it.
    static func text(item: WatchItem, pipeline: Pipeline) -> String? {
        let waiting = "waiting on " + pipeline.manualStages.joined(separator: ", ")
        let result: String? = switch (pipeline.state, item.role) {
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
        guard let result, let startedBy = item.startedBy else { return result }
        return result + ", by " + startedBy
    }
}
