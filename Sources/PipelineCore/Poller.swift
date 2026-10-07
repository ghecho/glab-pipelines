import Foundation

public enum PollOutcome: Sendable {
    case updated(Snapshot, [PipelineEvent])
    case failed(any Error)
}

@MainActor
public final class Poller {
    private let transport: any Transport
    /// A failed poll leaves this alone, so the next good poll still fires for a pipeline
    /// that ended during the outage.
    public private(set) var lastGood: Snapshot?

    private var sleeper: Task<Void, Never>?
    private var pollAgain = false

    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Polls until the calling task is cancelled. Only one poll runs at a time, so an older
    /// result can never replace a newer one.
    public func run(watched: () -> [ItemKey], onOutcome: (PollOutcome) async -> Void) async {
        while !Task.isCancelled {
            pollAgain = false
            let outcome = await poll(watched: watched())
            await onOutcome(outcome)
            if pollAgain { continue }
            let sleeper = Task { _ = try? await Task.sleep(for: Self.delay(after: outcome)) }
            self.sleeper = sleeper
            await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        }
    }

    /// Ends the wait at once. During a poll, `run` polls again as soon as it ends.
    public func pollNow() {
        pollAgain = true
        sleeper?.cancel()
    }

    public func poll(watched: [ItemKey]) async -> PollOutcome {
        do {
            let lists = try await transport.graphQL(MainQuery.buildLists())
            var batches: [WatchBatch] = []
            for keys in MainQuery.batches(watched) {
                do {
                    batches.append(WatchBatch(keys: keys, response: .success(try await transport.graphQL(MainQuery.buildWatches(keys)))))
                } catch {
                    batches.append(WatchBatch(keys: keys, response: .failure(error)))
                }
            }
            let snapshot = try MainQuery.decode(lists: lists, batches: batches)
            let events = Transitions.events(from: lastGood, to: snapshot)
            lastGood = snapshot
            return .updated(snapshot, events)
        } catch {
            return .failed(error)
        }
    }

    public nonisolated static func delay(after outcome: PollOutcome) -> Duration {
        switch outcome {
        case .failed: .seconds(60)
        case .updated(let snapshot, _): snapshot.anyRunning ? .seconds(10) : .seconds(30)
        }
    }
}
