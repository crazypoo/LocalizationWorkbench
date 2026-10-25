import Foundation

public enum LocalizationFormat: String, Codable, Sendable {
    case strings, stringsdict, xcstrings
}

public struct TranslationRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let group: String
    public let key: String
    public let variant: String
    public var values: [String: String]

    public init(group: String, key: String, variant: String = "", values: [String: String] = [:]) {
        self.group = group
        self.key = key
        self.variant = variant
        self.id = [group, key, variant].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        self.values = values
    }
}

public struct LocalizedDocument: Identifiable, Sendable {
    public let url: URL
    public let format: LocalizationFormat
    public let group: String
    public let language: String?
    public var id: String { url.path }
}

public struct LocalizationIssue: Identifiable, Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable { case warning, error }
    public let severity: Severity
    public let file: String
    public let detail: String
    public var id: String { file + "|" + severity.rawValue + "|" + detail }

    public init(_ severity: Severity, file: String, detail: String) {
        self.severity = severity
        self.file = file
        self.detail = detail
    }
}

public struct WorkspaceSnapshot: Sendable {
    public let root: URL
    public let documents: [LocalizedDocument]
    public let rows: [TranslationRow]
    public let languages: [String]
    public let issues: [LocalizationIssue]
    public let baselineFiles: [String: Data]
}

public enum LocalizationFailure: Error, LocalizedError {
    case malformed(String)
    case unsupported(String)
    case missing(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let s), .unsupported(let s), .missing(let s), .conflict(let s): return s
        }
    }
}
