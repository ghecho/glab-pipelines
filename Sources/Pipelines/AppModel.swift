import AppKit
import Observation
import PipelineCore
import ServiceManagement

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: Snapshot?
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    private(set) var expanded: Set<ItemKey> = []
    private(set) var details: [ItemKey: PipelineDetail] = [:]
    private(set) var rowErrors: [ItemKey: String] = [:]
    let watchList = WatchList()
    let notifier = Notifier()
    let prefs = ListPrefs()
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

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

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        // macOS can ask you to allow the login item first. Its switch is in System Settings.
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = status == .enabled
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
            prefs.keep(only: snapshot.knownKeys)
            ListRules.visibleEvents(events, hidden: prefs.hidden).forEach(notifier.post)
        case .failed(let error):
            self.error = error.localizedDescription
        }
    }

    func toggle(_ key: ItemKey) {
        if expanded.remove(key) != nil {
            details[key] = nil
        } else {
            expanded.insert(key)
            Task { await loadDetail(key) }
        }
    }

    /// The detail follows the item's current pipeline, so after a new push it shows the new stages.
    private func loadDetail(_ key: ItemKey) async {
        guard let transport, let pipeline = snapshot?.item(for: key)?.pipeline else { return }
        do {
            let query = PipelineQuery.build(project: key.project, pipelineID: pipeline.id)
            details[key] = try PipelineQuery.decode(try await transport.graphQL(query))
            rowErrors[key] = nil
        } catch {
            rowErrors[key] = error.localizedDescription
        }
    }

    /// False when the text is not a URL the app can watch, or when GitLab has no such pipeline.
    func addWatched(_ text: String) async -> Bool {
        switch WatchInput(text) {
        case .item(let key):
            watchList.add(key)
        case .pipeline(let project, let id):
            guard let transport,
                  let data = try? await transport.graphQL(PipelineQuery.buildBranchLookup(project: project, pipelineID: id)),
                  let branch = try? PipelineQuery.decodeBranch(data)
            else { return false }
            watchList.add(.branch(BranchKey(project: project, branch: branch)))
        case nil:
            return false
        }
        pollNow()
        return true
    }

    func removeWatched(_ key: ItemKey) {
        watchList.remove(key)
        pollNow()
    }

    func retry(_ job: Job, in item: WatchItem) {
        act(on: item.key) { try await $0.retryJob(project: item.key.project, jobID: job.id) }
    }

    func retryFailed(in item: WatchItem) {
        guard let pipeline = item.pipeline else { return }
        act(on: item.key) { try await $0.retryPipeline(project: item.key.project, pipelineID: pipeline.id) }
    }

    func play(_ job: Job, in item: WatchItem) {
        act(on: item.key) { try await $0.playJob(project: item.key.project, jobID: job.id) }
    }

    private func act(on key: ItemKey, _ action: @escaping @MainActor (GlabTransport) async throws -> Void) {
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
