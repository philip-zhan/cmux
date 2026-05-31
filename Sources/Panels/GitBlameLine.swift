import Foundation

/// Blame metadata for a single source line, as parsed from
/// `git blame --line-porcelain`.
///
/// One value per line of the blamed file, in file order. Sent across the
/// CodeMirror WKWebView bridge to drive the current-line inline annotation, so
/// it is `Codable` with compact wire keys.
struct GitBlameLine: Codable, Equatable {
    /// Abbreviated commit SHA (first 8 hex chars), or empty for uncommitted lines.
    let shortHash: String
    /// Commit author display name. `"You"` is substituted for uncommitted lines.
    let author: String
    /// Author time as Unix epoch seconds. `0` for uncommitted lines.
    let timestamp: Int
    /// Commit summary (first line of the message). Empty for uncommitted lines.
    let summary: String
    /// True when the line is not yet committed (working-tree change).
    let isUncommitted: Bool

    enum CodingKeys: String, CodingKey {
        case shortHash = "h"
        case author = "a"
        case timestamp = "t"
        case summary = "s"
        case isUncommitted = "u"
    }
}
