import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public struct ProcessError: Error, Sendable, CustomStringConvertible {
    public let command: String
    public let result: ProcessResult?
    public let reason: String

    public var description: String {
        let detail = result.map { $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return "\(command): \(reason)\(detail.isEmpty ? "" : " — \(detail)")"
    }
}

/// Runs a command and returns its output, entirely off the calling actor: output is read concurrently (so a full
/// pipe never deadlocks), termination is awaited, never waited on, and a timeout or task cancellation terminates it.
public enum ProcessRunner {
    public static func run(
        _ executable: String, _ arguments: [String], in directory: String? = nil,
        environment: [String: String]? = nil, timeout: Duration = .seconds(30), input: URL? = nil, stdin: Data? = nil
    ) async throws -> ProcessResult {
        let command = ([executable] + arguments).joined(separator: " ")
        // A bare name is resolved through tool detection (an app opened from Finder has a minimal PATH) and runs with
        // the detected PATH, so gh finds git and git its helpers. A path runs as given.
        var path = executable
        var variables = environment ?? [:]
        if !executable.contains("/") {
            let found = await ToolLocator.shared.executable(executable)
            guard let resolved = found.path else {
                throw ProcessError(
                    command: command, result: nil,
                    reason: "\(executable) not found (set [tools] \(executable) in config.toml)"
                )
            }
            path = resolved
            if variables["PATH"] == nil { variables["PATH"] = found.pathVariable }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if !variables.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(variables) { _, new in new }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // A file or bytes to read from (a bridge request), else nothing: a command must never wait on input.
        let feed = stdin.map { _ in Pipe() }
        if let feed {
            process.standardInput = feed
        } else if let input, let handle = try? FileHandle(forReadingFrom: input) {
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            throw ProcessError(command: command, result: nil, reason: "could not start (\(error.localizedDescription))")
        }
        if let feed, let stdin {
            // Written off the caller, then closed, so the command sees the end of its input. A command that exits
            // without reading must not take Heed down with SIGPIPE.
            _ = fcntl(feed.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            Task.detached {
                try? feed.fileHandleForWriting.write(contentsOf: stdin)
                try? feed.fileHandleForWriting.close()
            }
        }

        let timedOut = Flag()
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.set()
            process.terminate()
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            var status: Int32 = -1
            for await code in exited {
                status = code
            }
            let result = await ProcessResult(
                status: status,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
            if timedOut.isSet {
                throw ProcessError(command: command, result: result, reason: "timed out after \(timeout)")
            }
            return result
        } onCancel: {
            process.terminate()
        }
    }

    /// Runs and throws unless the command succeeded.
    public static func output(
        _ executable: String, _ arguments: [String], in directory: String? = nil, timeout: Duration = .seconds(30)
    ) async throws -> String {
        let result = try await run(executable, arguments, in: directory, timeout: timeout)
        guard result.succeeded else {
            throw ProcessError(
                command: ([executable] + arguments).joined(separator: " "), result: result,
                reason: "exit \(result.status)"
            )
        }
        return result.stdout
    }
}

public extension ProcessRunner {
    /// Runs a command and hands over its output as it comes, chunk by chunk, off the calling actor. Ending the stream
    /// early (the consumer stops, or its task is cancelled) terminates the command. Finishes when the command exits;
    /// an exit status not in `success` is thrown.
    static func stream(
        _ executable: String, _ arguments: [String], in directory: String? = nil, success: Set<Int32> = [0]
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let starting = Task.detached {
                let command = ([executable] + arguments).joined(separator: " ")
                var path = executable
                var environment = ProcessInfo.processInfo.environment
                if !executable.contains("/") {
                    let found = await ToolLocator.shared.executable(executable)
                    guard let resolved = found.path else {
                        continuation.finish(throwing: ProcessError(
                            command: command, result: nil,
                            reason: "\(executable) not found (set [tools] \(executable) in config.toml)"
                        ))
                        return
                    }
                    path = resolved
                    environment["PATH"] = found.pathVariable
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment
                if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                let reading = stdout.fileHandleForReading
                // The last chunk is read before the stream finishes, so nothing printed just before exit is lost.
                let drained = Flag()
                reading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        drained.set()
                    } else {
                        continuation.yield(data)
                    }
                }
                process.terminationHandler = { finished in
                    // A child that kept the pipe open would never send its end: give up after two seconds.
                    for _ in 0 ..< 1000 where !drained.isSet {
                        usleep(2000)
                    }
                    let status = finished.terminationStatus
                    if success.contains(status) || finished.terminationReason == .uncaughtSignal {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ProcessError(
                            command: command, result: nil, reason: "exit \(status)"
                        ))
                    }
                }
                continuation.onTermination = { _ in
                    if process.isRunning { process.terminate() }
                }
                guard !Task.isCancelled else {
                    reading.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                do {
                    try process.run()
                } catch {
                    reading.readabilityHandler = nil
                    continuation.finish(throwing: ProcessError(
                        command: command, result: nil, reason: "could not start (\(error.localizedDescription))"
                    ))
                }
            }
            continuation.onTermination = { _ in starting.cancel() }
        }
    }
}

/// A one-way flag shared with the watchdog task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
