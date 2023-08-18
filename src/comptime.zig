const std = @import("std");
const builtin = @import("builtin");

const Archetype = @import("Archetype.zig");

const is_debug = builtin.mode == .Debug;

/// Returns a unique comptime usize integer representing the type T. Value will change across
/// different compilations.
pub fn typeId(comptime T: type) u32 {
    _ = T;
    return @truncate(@intFromPtr(&struct {
        var x: u8 = 0;
    }.x));
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

/// Asserts that a tuple `row` to be e.g. appended to an archetype has values that actually match
/// all of the columns of the archetype table.
pub inline fn debugAssertRowType(storage: *Archetype, row: anytype) void {
    if (is_debug) {
        inline for (std.meta.fields(@TypeOf(row)), 0..) |field, index| {
            debugAssertColumnType(storage, &storage.columns[index], field.type);
        }
    }
}
