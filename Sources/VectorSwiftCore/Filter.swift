/// Boolean predicate tree over point payloads.
///
/// Values compare by case: equality for all cases; ordering for numeric and string
/// scalars when range operators are used. Evaluation is performed by the query
/// layer when filtering is enabled; the AST itself is pure data.
public indirect enum Filter: Sendable, Codable, Equatable {
    case eq(String, PayloadValue)
    case neq(String, PayloadValue)
    case gte(String, PayloadValue)
    case lte(String, PayloadValue)
    case `in`(String, [PayloadValue])
    case and([Filter])
    case or([Filter])
    case not(Filter)
}
