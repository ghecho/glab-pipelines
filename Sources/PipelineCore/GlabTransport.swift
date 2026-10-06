import Foundation

public enum GlabError: Error, Equatable, LocalizedError {
    case notFound(searched: [String])
    case notLoggedIn
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched): "glab not found. Looked in: " + searched.joined(separator: ", ")
        case .notLoggedIn: "Run glab auth login"
        case .timedOut: "glab did not answer within 20 seconds"
        case .failed(let message): message
        }
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Lets the timeout timer reach the process from another thread.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

/// Written by one reader thread, read after `DispatchGroup.wait()`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

public struct GlabTransport: Transport {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// A menubar app does not get the PATH of your shell, so look in the Homebrew
    /// locations first and then ask a login shell.
    public static func locate() throws -> URL {
        let candidates = ["/opt/homebrew/bin/glab", "/usr/local/bin/glab"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        if let result = try? runBlocking(URL(filePath: "/bin/zsh"), ["-lc", "command -v glab"], timeout: 5),
           result.status == 0 {
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(filePath: path) }
        }
        throw GlabError.notFound(searched: candidates + ["zsh -lc 'command -v glab'"])
    }

    public func graphQL(_ query: String) async throws -> Data {
        let result = try await run(["api", "graphql", "-f", "query=\(query)"])
        // On a GraphQL error glab exits 1 but still prints the response. Data next to the
        // errors is partial data, and the decoder can use it.
        if result.status == 0 || Self.hasData(result.stdout) { return result.stdout }
        throw Self.classify(stderr: String(decoding: result.stderr, as: UTF8.self))
    }

    public func retryJob(project: String, jobID: Int) async throws {
        try await action(["ci", "retry", String(jobID), "-R", project])
    }

    public func playJob(project: String, jobID: Int) async throws {
        try await action(["ci", "trigger", String(jobID), "-R", project])
    }

    public func retryPipeline(project: String, pipelineID: Int) async throws {
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        try await action(["api", "-X", "POST", "projects/\(encoded)/pipelines/\(pipelineID)/retry"])
    }

    private func action(_ arguments: [String]) async throws {
        let result = try await run(arguments)
        guard result.status == 0 else {
            throw Self.classify(stderr: String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        let executable = executable
        return try await Task.detached {
            try Self.runBlocking(executable, arguments, timeout: 20)
        }.value
    }

    static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if box.process.isRunning { box.process.terminate() }
        }
        // A process that fills a 64 KB pipe buffer blocks until someone reads it. Read both
        // pipes at the same time, and to the end, before waiting for the exit.
        let err = DataBox()
        let errHandle = stderr.fileHandleForReading
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { err.data = errHandle.readDataToEndOfFile() }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal { throw GlabError.timedOut }
        return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err.data)
    }

    static func classify(stderr: String) -> GlabError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("Invalid token") || message.contains("401") { return .notLoggedIn }
        return .failed(message.hasPrefix("glab: ") ? String(message.dropFirst(6)) : message)
    }

    static func hasData(_ stdout: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let data = object["data"]
        else { return false }
        return !(data is NSNull)
    }
}
