import AppKit
import Observation
import PipelineCore

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: Snapshot?
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    private(set) var expanded: Set<MRKey> = []
    private(set) var details: [MRKey: PipelineDetail] = [:]
    private(set) var rowErrors: [MRKey: String] = [:]
    let watchList = WatchList()
    let notifier = Notifier()

    private var transport: GlabTransport?
    private var poller: Poller?

    func start() {
        Task { await notifier.start() }
        do {
            let transport = GlabTransport(executable: try GlabTransport.locate())
            self.transport = transport
            let poller = Poller(transport: transport)
            self.poller = poller
            Task {
                await poller.run(watched: { watchList.keys }) { outcome in
                    apply(outcome)
                    for key in expanded { await loadDetail(key) }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pollNow() {
        poller?.pollNow()
    }

    private func apply(_ outcome: PollOutcome) {
        switch outcome {
        case .updated(let snapshot, let events):
            self.snapshot = snapshot
            lastUpdated = .now
            error = nil
            snapshot.closedWatched.forEach(watchList.remove)
            events.forEach(notifier.post)
        case .failed(let error):
            self.error = error.localizedDescription
        }
    }

    func toggle(_ key: MRKey) {
        if expanded.remove(key) != nil {
            details[key] = nil
        } else {
            expanded.insert(key)
            Task { await loadDetail(key) }
        }
    }

    private func loadDetail(_ key: MRKey) async {
        guard let transport else { return }
        do {
            details[key] = try PipelineQuery.decode(try await transport.graphQL(PipelineQuery.build(key)))
            rowErrors[key] = nil
        } catch {
            rowErrors[key] = error.localizedDescription
        }
    }

    func addWatched(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let key = MRKey(url: url)
        else { return false }
        watchList.add(key)
        pollNow()
        return true
    }

    func removeWatched(_ key: MRKey) {
        watchList.remove(key)
        pollNow()
    }

    func retry(_ job: Job, in mergeRequest: MergeRequest) {
        act(on: mergeRequest.key) { try await $0.retryJob(project: mergeRequest.key.project, jobID: job.id) }
    }

    func retryFailed(in mergeRequest: MergeRequest) {
        guard let pipeline = mergeRequest.pipeline else { return }
        act(on: mergeRequest.key) { try await $0.retryPipeline(project: mergeRequest.key.project, pipelineID: pipeline.id) }
    }

    func play(_ job: Job, in mergeRequest: MergeRequest) {
        act(on: mergeRequest.key) { try await $0.playJob(project: mergeRequest.key.project, jobID: job.id) }
    }

    private func act(on key: MRKey, _ action: @escaping @MainActor (GlabTransport) async throws -> Void) {
        guard let transport else { return }
        Task {
            do {
                try await action(transport)
                rowErrors[key] = nil
                pollNow()
            } catch {
                rowErrors[key] = error.localizedDescription
            }
        }
    }
}
