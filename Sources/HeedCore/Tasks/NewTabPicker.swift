import Foundation

/// `⌘T`: what the new tab shows. A kind's key opens it, `↩` (or `⌘T` again) opens the kind used last, `⎋` cancels.
public struct NewTabPicker: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case terminal
        case page

        /// The key that picks it in the dialog.
        public var key: String {
            switch self {
            case .terminal: "t"
            case .page: "b"
            }
        }

        public var label: String {
            switch self {
            case .terminal: "Terminal"
            case .page: "Web page"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case handled
        case cancel
        case open(Kind)
    }

    /// What `↩` opens.
    public let last: Kind

    public init(last: Kind) {
        self.last = last
    }

    public func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape, KeyStroke("q"): return .cancel
        case KeyStroke("CR"), KeyStroke("t", .command): return .open(last)
        default:
            guard stroke.modifiers.isEmpty, let kind = Kind.allCases.first(where: { $0.key == stroke.key }) else {
                return .handled
            }
            return .open(kind)
        }
    }
}
