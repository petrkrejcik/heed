import Foundation

/// How a prompt reaches an agent.
public enum PromptDelivery: String, Sendable, Codable, CaseIterable {
    /// As a quoted command-line argument: `claude "<prompt>"`.
    case argument
    /// Piped on stdin.
    case stdin
    /// Typed into the pty once the agent is up.
    case paste
    /// Written to a file whose path is passed.
    case file
}

/// The agent as config describes it (`[agents.claude]`).
public struct AgentProfile: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    /// The executable plus fixed arguments, e.g. `claude` or `claude --model opus`.
    public var command: String
    public var prompt: PromptDelivery
    /// Named variants, e.g. `plan = "claude --permission-mode plan"`.
    public var profiles: [String: String]
    /// Arguments that make the agent plan before acting, for Start work's "Plan first".
    public var planArguments: String?
    /// Arguments that resume the agent's session `{id}`, e.g. `--resume {id}`. Nil: the agent cannot resume, so a
    /// restored session starts fresh with its prompt.
    public var resumeArguments: String?
    /// Flag that assigns the agent's own session id at launch (`--session-id`), so resume works from the start.
    public var sessionIDFlag: String?
    /// Flag that picks the model (`--model`), for get it green runs that choose one; nil: the agent cannot.
    public var modelFlag: String?

    public init(
        name: String, command: String, prompt: PromptDelivery = .argument, profiles: [String: String] = [:],
        planArguments: String? = nil, resumeArguments: String? = nil, sessionIDFlag: String? = nil
    ) {
        self.resumeArguments = resumeArguments
        self.sessionIDFlag = sessionIDFlag
        self.name = name
        self.command = command
        self.prompt = prompt
        self.profiles = profiles
        self.planArguments = planArguments
    }

    /// The command line typed into the session's shell to start the agent on `prompt`.
    public func launchCommand(
        prompt text: String, planFirst: Bool = false, extraArguments: [String] = [], model: String? = nil
    ) -> String {
        var line = ([command] + extraArguments.map(ShellQuote.quote)).joined(separator: " ")
        if let model, !model.isEmpty, let modelFlag { line += " \(modelFlag) \(ShellQuote.quote(model))" }
        if planFirst, let planArguments { line += " " + planArguments }
        guard !text.isEmpty else { return line }
        switch prompt {
        case .argument: return line + " " + ShellQuote.quote(text)
        case .stdin: return "printf '%s' \(ShellQuote.quote(text)) | " + line
        case .paste, .file: return line
        }
    }

    /// The command line that resumes session `id`, or nil when this agent cannot resume.
    public func resumeCommand(
        id: String, extraArguments: [String] = []
    ) -> String? {
        guard let resumeArguments else { return nil }
        let resume = resumeArguments.replacingOccurrences(of: "{id}", with: ShellQuote.quote(id))
        return ([command] + extraArguments.map(ShellQuote.quote) + [resume]).joined(separator: " ")
    }

    /// The only agent: Claude has the hooks. Others run in a plain terminal tab, without status.
    public static let builtIn: [AgentProfile] = {
        var claude = AgentProfile(
            name: "claude", command: "claude", planArguments: "--permission-mode plan",
            resumeArguments: "--resume {id}",
            sessionIDFlag: "--session-id"
        )
        claude.modelFlag = "--model"
        return [claude]
    }()
}

/// POSIX shell quoting for command lines Heed types into a shell.
public enum ShellQuote {
    /// Single-quotes `text` unless it is made only of safe characters.
    public static func quote(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
