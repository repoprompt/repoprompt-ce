import Foundation

public enum GitDiffTarget: Codable, Sendable, Equatable, Hashable {
    case uncommitted(base: String)
    case uncommittedMergeBase(base: String)
    case commit(sha: String)
    case range(from: String, to: String)

    public enum Kind: String, Codable, Sendable {
        case uncommitted
        case uncommittedMergeBase
        case commit
        case range
    }

    public var kind: Kind {
        switch self {
        case .uncommitted:
            .uncommitted
        case .uncommittedMergeBase:
            .uncommittedMergeBase
        case .commit:
            .commit
        case .range:
            .range
        }
    }

    public var baseRef: String {
        switch self {
        case let .uncommitted(base):
            base
        case let .uncommittedMergeBase(base):
            base
        case let .commit(sha):
            sha
        case let .range(from, to):
            "\(from)..\(to)"
        }
    }

    public var keyString: String {
        switch self {
        case let .uncommitted(base):
            "uncommitted:\(base)"
        case let .uncommittedMergeBase(base):
            "uncommitted-mergebase:\(base)"
        case let .commit(sha):
            "commit:\(sha)"
        case let .range(from, to):
            "range:\(from)..\(to)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case base
        case sha
        case from
        case to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .uncommitted:
            let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
            self = .uncommitted(base: base)
        case .uncommittedMergeBase:
            let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
            self = .uncommittedMergeBase(base: base)
        case .commit:
            let sha = try container.decode(String.self, forKey: .sha)
            self = .commit(sha: sha)
        case .range:
            let from = try container.decode(String.self, forKey: .from)
            let to = try container.decode(String.self, forKey: .to)
            self = .range(from: from, to: to)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .uncommitted(base):
            try container.encode(Kind.uncommitted, forKey: .kind)
            try container.encode(base, forKey: .base)
        case let .uncommittedMergeBase(base):
            try container.encode(Kind.uncommittedMergeBase, forKey: .kind)
            try container.encode(base, forKey: .base)
        case let .commit(sha):
            try container.encode(Kind.commit, forKey: .kind)
            try container.encode(sha, forKey: .sha)
        case let .range(from, to):
            try container.encode(Kind.range, forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        }
    }
}
