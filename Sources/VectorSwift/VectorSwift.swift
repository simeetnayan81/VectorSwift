@_exported import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex
import VectorSwiftQuery

/// Public library product. Import this module from apps and services.
public enum VectorSwift: Sendable {
    /// Library name for diagnostics.
    public static let name = "VectorSwift"

    /// Names of modules linked into this product (used by smoke tests).
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
