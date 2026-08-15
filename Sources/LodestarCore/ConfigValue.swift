import Foundation

/// A parsed configuration value — the shared shape any config syntax
/// produces.
public enum ConfigValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case table([String: ConfigValue])

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .int(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var table: [String: ConfigValue]? { if case .table(let v) = self { return v }; return nil }

    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}

public extension Dictionary where Key == String, Value == ConfigValue {
    /// Walk a path from this tree's root; nil when any hop is missing or is
    /// a scalar where a table was needed. Syntax-agnostic: the tree is the
    /// same shape whichever parser produced it.
    func value(at path: [String]) -> ConfigValue? {
        var current: ConfigValue = .table(self)
        for hop in path {
            guard let table = current.table, let next = table[hop] else { return nil }
            current = next
        }
        return current
    }
}
