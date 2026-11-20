import Foundation

/// The keep-warm ping: a headless Claude that resumes the agent's session, answers "pong" and is gone, never typed
/// into the tab. `--no-session-persistence` leaves the session file as it was; `--model` is the session's own, since
/// another model has its own cache and would miss. Run without Heed's hook settings or env, its hooks report nowhere.
public enum ClaudePing {
    /// What a ping read from and wrote to the cache, what it cost, and how long it took.
    public struct Result: Equatable, Sendable {
        public var read: Int
        public var written: Int
        public var cost: Double
        public var seconds: Double

        public init(read: Int, written: Int, cost: Double, seconds: Double) {
            self.read = read
            self.written = written
            self.cost = cost
            self.seconds = seconds
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    public static let prompt = #"Reply with just "pong""#
    public static let timeout: Duration = .seconds(60)

    public static func arguments(sessionID: String, model: String) -> [String] {
        [
            "-p", "--resume", sessionID, "--no-session-persistence", "--model", model, "--output-format", "json",
            prompt,
        ]
    }

    /// Pings session `sessionID` of the agent run as `command` (`[agents.claude] command`) in `directory`, where it
    /// works. Off the main actor: it reads the session file and waits up to a minute for Claude.
    public static func run(
        command: String, sessionID: String, directory: String, home: String = NSHomeDirectory()
    ) async throws -> Result {
        let file = "\(home)/.claude/projects/\(AgentIntegration.claudeProjectFolder(directory))/\(sessionID).jsonl"
        guard let data = FileManager.default.contents(atPath: file) else {
            throw Failure(description: "Claude no longer has the session")
        }
        guard let model = model(inSession: data) else { throw Failure(description: "no reply in the session yet") }
        let words = command.split(separator: " ").map(String.init)
        let unset = [HeedEnvironment.sessionID: "", HeedEnvironment.socket: "", HeedEnvironment.pane: ""]
        let output: ProcessResult
        do {
            output = try await ProcessRunner.run(
                words.first ?? "claude", Array(words.dropFirst()) + arguments(sessionID: sessionID, model: model),
                in: directory, environment: unset, timeout: timeout
            )
        } catch {
            throw Failure(description: "\(error)")
        }
        guard output.succeeded else {
            let line = output.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            throw Failure(description: line ?? "claude exited with \(output.status)")
        }
        return try result(fromJSON: Data(output.stdout.utf8))
    }

    /// The model of the session's last reply: the last `assistant` line of its session file with a real model.
    public static func model(inSession data: Data) -> String? {
        struct Line: Decodable {
            struct Message: Decodable { let model: String? }
            let type: String?
            let message: Message?
        }
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? decoder.decode(Line.self, from: Data(line)), entry.type == "assistant",
                  let model = entry.message?.model, !model.isEmpty, !model.hasPrefix("<")
            else { continue }
            return model
        }
        return nil
    }

    /// The reply of `--output-format json`.
    public static func result(fromJSON data: Data) throws -> Result {
        struct Reply: Decodable {
            struct Usage: Decodable {
                let read: Int?
                let written: Int?
                enum CodingKeys: String, CodingKey {
                    case read = "cache_read_input_tokens", written = "cache_creation_input_tokens"
                }
            }

            let isError: Bool?
            let result: String?
            let cost: Double?
            let milliseconds: Double?
            let usage: Usage?
            enum CodingKeys: String, CodingKey {
                case isError = "is_error", result, cost = "total_cost_usd", milliseconds = "duration_ms", usage
            }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw Failure(description: "Claude's reply was not its JSON")
        }
        if reply.isError == true { throw Failure(description: reply.result ?? "Claude answered with an error") }
        return Result(
            read: reply.usage?.read ?? 0, written: reply.usage?.written ?? 0, cost: reply.cost ?? 0,
            seconds: (reply.milliseconds ?? 0) / 1000
        )
    }
}
