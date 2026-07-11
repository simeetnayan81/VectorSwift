import VectorSwiftCore

/// Identity marker for the Compute module (distance and vector kernels).
public enum VectorSwiftComputeModule: Sendable {
    public static let moduleName = "VectorSwiftCompute"
    public static let dependsOnCore = VectorSwiftCoreModule.moduleName
}
