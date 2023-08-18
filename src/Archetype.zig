//! Represents a single archetype. i.e., entities which have a specific set of components. When a
//! component is added or removed from an entity, it's archetype changes because the archetype is
//! the set of components an entity has.
//!
//! Database equivalent: a table where rows are entities and columns are components (dense storage).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");
const StringTable = @import("StringTable.zig");
const comp = @import("comptime.zig");

const Archetype = @This();

/// Describes a single column of the archetype (table); i.e. a single type of component
pub const Column = struct {
    /// The unique name of the component this column stores.
    name: StringTable.Index,

    /// A unique identifier for the programming-language type this column stores. In the case of Zig
    /// this is a comptime type identifier. For other languages, it may be something else or simply
    /// zero if unused.
    ///
    /// This value need only uniquely identify the column type for the duration of a single build of
    /// the program.
    type_id: u32,

    /// The size of the component this column stores.
    size: u32,

    /// The alignment of the component type this column stores.
    alignment: u16,

    /// The actual memory where the values are stored. The length/capacity is Archetype.len and
    /// Archetype.capacity, as all columns in an Archetype have identical lengths/capacities.
    values: []u8,
};

/// The length of the table (in-use number of rows)
len: u32,

/// The capacity of the table (total allocated number of rows)
capacity: u32,

/// Describes the columns in this table. Each column stores all rows for that column.
columns: []Column,

/// A reference to the string table that can be used to identify Column.name's
component_names: *StringTable,

/// A hash composed of all Column.name's, effectively acting as the unique name of this table.
hash: u64,

/// An index to Entities.archetypes, used in the event of a *bucket* hash collision (not a collision
/// of the .hash field) - see Entities.archetypeOrPut for details.
next: ?u32 = null,

// TODO: comptime refactor
pub fn Slicer(comptime all_components: anytype) type {
    return struct {
        archetype: *Archetype,

        pub fn slice(
            slicer: @This(),
            comptime namespace_name: std.meta.FieldEnum(@TypeOf(all_components)),
            comptime component_name: std.meta.FieldEnum(@TypeOf(@field(all_components, @tagName(namespace_name)))),
        ) []@field(
            @field(all_components, @tagName(namespace_name)),
            @tagName(component_name),
        ) {
            const Type = @field(
                @field(all_components, @tagName(namespace_name)),
                @tagName(component_name),
            );
            if (namespace_name == .entity and component_name == .id) {
                const name_id = slicer.archetype.component_names.index("id").?;
                return slicer.archetype.getColumnValues(name_id, Type).?[0..slicer.archetype.len];
            }
            const name = @tagName(namespace_name) ++ "." ++ @tagName(component_name);
            const name_id = slicer.archetype.component_names.index(name).?;
            return slicer.archetype.getColumnValues(name_id, Type).?[0..slicer.archetype.len];
        }
    };
}

pub fn deinit(storage: *Archetype, gpa: Allocator) void {
    if (storage.capacity > 0) {
        for (storage.columns) |column| gpa.free(column.values);
    }
    gpa.free(storage.columns);
}

/// appends a new row to this table, with all undefined values.
pub fn appendUndefined(storage: *Archetype, gpa: Allocator) !u32 {
    try storage.ensureUnusedCapacity(gpa, 1);
    assert(storage.len < storage.capacity);
    const row_index = storage.len;
    storage.len += 1;
    return row_index;
}

// TODO: comptime refactor
pub fn append(storage: *Archetype, gpa: Allocator, row: anytype) !u32 {
    comp.debugAssertRowType(storage, row);

    try storage.ensureUnusedCapacity(gpa, 1);
    assert(storage.len < storage.capacity);
    storage.len += 1;

    storage.setRow(storage.len - 1, row);
    return storage.len;
}

pub fn undoAppend(storage: *Archetype) void {
    storage.len -= 1;
}

/// Ensures there is enough unused capacity to store `num_rows`.
pub fn ensureUnusedCapacity(storage: *Archetype, gpa: Allocator, num_rows: usize) !void {
    return storage.ensureTotalCapacity(gpa, storage.len + num_rows);
}

/// Ensures the total capacity is enough to store `new_capacity` rows total.
pub fn ensureTotalCapacity(storage: *Archetype, gpa: Allocator, new_capacity: usize) !void {
    var better_capacity = storage.capacity;
    if (better_capacity >= new_capacity) return;

    while (true) {
        better_capacity +|= better_capacity / 2 + 8;
        if (better_capacity >= new_capacity) break;
    }

    return storage.setCapacity(gpa, better_capacity);
}

/// Sets the capacity to exactly `new_capacity` rows total
///
/// Asserts `new_capacity >= storage.len`, if you want to shrink capacity then change the len
/// yourself first.
pub fn setCapacity(storage: *Archetype, gpa: Allocator, new_capacity: usize) !void {
    assert(new_capacity >= storage.len);

    // TODO: ensure columns are sorted by type_id
    for (storage.columns) |*column| {
        const old_values = column.values;
        const new_values = try gpa.alloc(u8, new_capacity * column.size);
        if (storage.capacity > 0) {
            std.mem.copy(u8, new_values[0..], old_values);
            gpa.free(old_values);
        }
        column.values = new_values;
    }
    storage.capacity = @as(u32, @intCast(new_capacity));
}

// TODO: comptime refactor
/// Sets the entire row's values in the table.
pub fn setRow(storage: *Archetype, row_index: u32, row: anytype) void {
    comp.debugAssertRowType(storage, row);

    const fields = std.meta.fields(@TypeOf(row));
    inline for (fields, 0..) |field, index| {
        const ColumnType = field.type;
        if (@sizeOf(ColumnType) == 0) continue;

        var column = storage.columns[index];
        const column_values = @as([*]ColumnType, @ptrCast(@alignCast(column.values.ptr)));
        column_values[row_index] = @field(row, field.name);
    }
}

// TODO: comptime refactor
/// Sets the value of the named components (columns) for the given row in the table.
pub fn set(storage: *Archetype, row_index: u32, name: StringTable.Index, component: anytype) void {
    const ColumnType = @TypeOf(component);
    if (@sizeOf(ColumnType) == 0) return;
    if (comp.is_debug) comp.debugAssertColumnType(storage, storage.columnByName(name).?, @TypeOf(component));
    storage.setRaw(row_index, name, @as([*]const u8, @ptrCast(&component))[0..@sizeOf(@TypeOf(component))]);
}

// TODO: comptime refactor
pub fn get(storage: *Archetype, row_index: u32, name: StringTable.Index, comptime ColumnType: type) ?ColumnType {
    if (@sizeOf(ColumnType) == 0) return {};
    if (comp.is_debug) comp.debugAssertColumnType(storage, storage.columnByName(name) orelse return null, ColumnType);

    const bytes = storage.getRaw(row_index, name, @sizeOf(ColumnType)) orelse return null;
    return @as(*ColumnType, @alignCast(@ptrCast(bytes.ptr))).*;
}

pub fn getRaw(storage: *Archetype, row_index: u32, name: StringTable.Index, size: u32) ?[]u8 {
    const values = storage.getRawColumnValues(name) orelse return null;
    if (comp.is_debug) {
        assert(storage.columnByName(name).?.size == size);
        // TODO: type_id verification
    }

    const start = size * row_index;
    const end = start + size;
    return values[start..end];
}

pub fn setRaw(storage: *Archetype, row_index: u32, name: StringTable.Index, component: []const u8) void {
    if (comp.is_debug) {
        assert(storage.len != 0 and storage.len >= row_index);
        assert(storage.columnByName(name).?.size == component.len);
        // TODO: type_id verification
    }

    const values = storage.getRawColumnValues(name) orelse @panic("no such component");
    const start = component.len * row_index;
    std.mem.copy(u8, values[start..], component);
}

/// Swap-removes the specified row with the last row in the table.
pub fn remove(storage: *Archetype, row_index: u32) void {
    if (storage.len > 1) {
        for (storage.columns) |column| {
            const dstStart = column.size * row_index;
            const dst = column.values[dstStart .. dstStart + column.size];
            const srcStart = column.size * (storage.len - 1);
            const src = column.values[srcStart .. srcStart + column.size];
            std.mem.copy(u8, dst, src);
        }
    }
    storage.len -= 1;
}

/// Tells if this archetype has every one of the given components.
pub fn hasComponents(storage: *Archetype, names: []const u32) bool {
    for (names) |name| {
        if (!storage.hasComponent(name)) return false;
    }
    return true;
}

/// Tells if this archetype has a component with the specified name.
pub fn hasComponent(storage: *Archetype, name: StringTable.Index) bool {
    for (storage.columns) |column| {
        if (column.name == name) return true;
    }
    return false;
}

// TODO: comptime refactor
pub fn getColumnValues(storage: *Archetype, name: StringTable.Index, comptime ColumnType: type) ?[]ColumnType {
    for (storage.columns) |*column| {
        if (column.name != name) continue;
        comp.debugAssertColumnType(storage, column, ColumnType);
        var ptr = @as([*]ColumnType, @ptrCast(@alignCast(column.values.ptr)));
        const column_values = ptr[0..storage.capacity];
        return column_values;
    }
    return null;
}

pub fn getRawColumnValues(storage: *Archetype, name: StringTable.Index) ?[]u8 {
    for (storage.columns) |column| {
        if (column.name != name) continue;
        return column.values;
    }
    return null;
}

pub inline fn columnByName(storage: *Archetype, name: StringTable.Index) ?*Column {
    for (storage.columns) |*column| {
        if (column.name == name) return column;
    }
    return null;
}
