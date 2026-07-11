/// Payload predicate AST (evaluation is separate).
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
