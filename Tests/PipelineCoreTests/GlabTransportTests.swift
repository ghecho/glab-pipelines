import Foundation
import Testing
@testable import PipelineCore

@Test func classifiesErrors() {
    #expect(GlabTransport.classify(stderr: "glab: Invalid token\n") == .notLoggedIn)
    #expect(GlabTransport.classify(stderr: "glab: 401 Unauthorized") == .notLoggedIn)
    #expect(GlabTransport.classify(stderr: "glab: Field 'bogus' doesn't exist on type 'Query'\n")
            == .failed("Field 'bogus' doesn't exist on type 'Query'"))
}

@Test func detectsPartialData() {
    #expect(GlabTransport.hasData(Data(#"{"data": {"a": 1}, "errors": [{"message": "x"}]}"#.utf8)))
    #expect(!GlabTransport.hasData(Data(#"{"errors": [{"message": "x"}]}"#.utf8)))
    #expect(!GlabTransport.hasData(Data(#"{"data": null}"#.utf8)))
    #expect(!GlabTransport.hasData(Data("not json".utf8)))
}

@Test func readsOutputLargerThanThePipeBuffer() throws {
    let result = try GlabTransport.runBlocking(
        URL(filePath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero"], timeout: 5
    )
    #expect(result.status == 0)
    #expect(result.stdout.count == 200_000)
}

@Test func capturesStderrAndExitStatus() throws {
    let result = try GlabTransport.runBlocking(URL(filePath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"], timeout: 5)
    #expect(result.status == 3)
    #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
}

@Test func stopsAProcessThatRunsTooLong() {
    #expect(throws: GlabError.timedOut) {
        try GlabTransport.runBlocking(URL(filePath: "/bin/sleep"), ["5"], timeout: 0.5)
    }
}

@Test func readsStderrLargerThanThePipeBuffer() throws {
    let result = try GlabTransport.runBlocking(
        URL(filePath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero >&2; echo done"], timeout: 5
    )
    #expect(result.stderr.count == 200_000)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
}
