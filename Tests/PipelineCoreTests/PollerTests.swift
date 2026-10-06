import Foundation
import Testing
@testable import PipelineCore

struct Offline: Error {}

actor FakeTransport: Transport {
    private var replies: [Result<Data, any Error>]
    private(set) var queries: [String] = []

    init(_ replies: [Result<Data, any Error>]) { self.replies = replies }

    func graphQL(_ query: String) async throws -> Data {
        queries.append(query)
        return try replies.removeFirst().get()
    }
    func retryJob(project: String, jobID: Int) async throws {}
    func playJob(project: String, jobID: Int) async throws {}
    func retryPipeline(project: String, pipelineID: Int) async throws {}
}

func events(_ outcome: PollOutcome) -> [String]? {
    if case .updated(_, let events) = outcome { return events.map(\.text) }
    return nil
}

@MainActor @Test func firstPollSetsTheBaseline() async {
    let poller = Poller(transport: FakeTransport([.success(response(authored: [mrNode(1, status: "FAILED")]))]))
    #expect(events(await poller.poll(watched: [])) == [])
    #expect(poller.lastGood?.mergeRequests.count == 1)
}

@MainActor @Test func failedPollKeepsTheLastGoodSnapshot() async {
    let poller = Poller(transport: FakeTransport([
        .success(response(authored: [mrNode(1, status: "RUNNING")])),
        .failure(Offline()),
        .success(response(authored: [mrNode(1, status: "SUCCESS")])),
    ]))
    _ = await poller.poll(watched: [])
    #expect(events(await poller.poll(watched: [])) == nil)
    #expect(poller.lastGood?.mergeRequests.first?.pipeline?.state == .running)
    #expect(events(await poller.poll(watched: [])) == ["Passed"])
}

@MainActor @Test func decodeErrorIsAFailedPoll() async {
    let poller = Poller(transport: FakeTransport([.success(Data(#"{"errors": [{"message": "nope"}]}"#.utf8))]))
    guard case .failed(let error) = await poller.poll(watched: []) else {
        Issue.record("expected a failed poll")
        return
    }
    #expect(error as? DecodeError == .noData(["nope"]))
}

@MainActor @Test func sendsTheWatchedAliases() async {
    let transport = FakeTransport([.success(response())])
    _ = await Poller(transport: transport).poll(watched: [MRKey(project: "a/b", iid: 3)])
    #expect(await transport.queries.first?.contains(#"w0: project(fullPath: "a/b")"#) == true)
}

@Test func delayFollowsTheSnapshot() {
    let running = Snapshot(mergeRequests: [mr(1, .reviewing, .running)], watchErrors: [:], closedWatched: [])
    #expect(Poller.delay(after: .updated(running, [])) == .seconds(10))
    #expect(Poller.delay(after: .updated(snapshot(mr(1, .authored, .passed)), [])) == .seconds(30))
    #expect(Poller.delay(after: .failed(Offline())) == .seconds(60))
}

actor SlowTransport: Transport {
    private(set) var calls = 0
    private(set) var maxInFlight = 0
    private var inFlight = 0

    func graphQL(_ query: String) async throws -> Data {
        calls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        try? await Task.sleep(for: .milliseconds(100))
        inFlight -= 1
        return response(authored: [mrNode(1, status: "SUCCESS")])
    }
    func retryJob(project: String, jobID: Int) async throws {}
    func playJob(project: String, jobID: Int) async throws {}
    func retryPipeline(project: String, pipelineID: Int) async throws {}
}

@MainActor @Test func pollNowNeverOverlapsAPoll() async throws {
    let transport = SlowTransport()
    let poller = Poller(transport: transport)
    var outcomes = 0
    let loop = Task { await poller.run(watched: { [] }, onOutcome: { _ in outcomes += 1 }) }
    try await Task.sleep(for: .milliseconds(20))
    poller.pollNow()
    poller.pollNow()
    try await Task.sleep(for: .milliseconds(400))
    #expect(await transport.calls == 2)
    #expect(await transport.maxInFlight == 1)

    // While the loop waits 30 seconds, pollNow polls at once.
    poller.pollNow()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await transport.calls == 3)
    #expect(outcomes == 3)
    loop.cancel()
}
