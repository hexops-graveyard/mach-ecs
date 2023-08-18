const std = @import("std");
const builtin = @import("builtin");

const Archetype = @import("Archetype.zig");

const is_debug = builtin.mode == .Debug;

/// Returns a unique comptime usize integer representing the type T. Value will change across
/// different compilations.
pub fn typeId(comptime T: type) usize {
    _ = T;
    return @intFromPtr(&struct {
        var x: u8 = 0;
    }.x);
}

/// Asserts that T matches the type of the column.
pub inline fn debugAssertColumnType(storage: *Archetype, column: *Archetype.Column, comptime T: type) void {
    if (is_debug) {
        if (typeId(T) != column.type_id) std.debug.panic("unexpected type: {s} expected: {s}", .{
            @typeName(T),
            storage.component_names.string(column.name),
        });
    }
}
