@_exported import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex
import VectorSwiftQuery

/// Public library product. Import this module from applications and services.
///
/// Re-exports `VectorSwiftCore` so types such as `Point`, `SearchRequest`, and
/// `VectorSwiftError` are available without a second import. Higher-level types
/// (`Database`, `Collection`) live in this module.
public enum VectorSwift: Sendable {
    /// Library name for diagnostics and smoke tests.
    public static let name = "VectorSwift"

    /// Module names linked into this product (used by package smoke tests).
    public static var linkedModules: [String] {
        [
            VectorSwiftCoreModule.moduleName,
            VectorSwiftComputeModule.moduleName,
            VectorSwiftIndexModule.moduleName,
            VectorSwiftQueryModule.moduleName,
            name,
        ]
    }
}
