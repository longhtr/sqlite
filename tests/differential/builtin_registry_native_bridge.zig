const registry = @import("registry_root").function_registry;

pub export fn native_builtin_registry_dump(visitor: registry.TopologyVisitor) callconv(.c) void {
    registry.resetAndRegisterPortedBuiltinFunctions();
    registry.visitPortedTopology(visitor);
}
