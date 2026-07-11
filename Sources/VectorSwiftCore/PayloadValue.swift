/// Schemaless payload value stored with a point.
public enum PayloadValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    /// Tag / multi-value string list.
    case strings([String])
}
