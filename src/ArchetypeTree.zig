//! ArchetypeTree is a generational tree of archetypes. Nodes are stored in a flat list and have
//! parent relations.
//!
//! The root node represents entities with no components i.e. it is an implicit entity [ID] node.
//! An archetype is described by its entire chain of nodes up to the root node, i.e. children
//! represent *additions of components* to a parent. For example if a Location component is added to
//! the root node then two archetypes would exist: [ID] and [ID, Location], with [ID] being the root
//! node and [ID, Location] being a child node.
//!
//! Children can have more than one parent; and smaller component names always come first. e.g. if
//! ID=0, Location=2, and Rotation=1 then adding Rotation to the [ID, Location] archetype node would
//! result in an archetype [ID=0, Rotation=1, Location=2] instead of [ID=0, Location=2, Rotation=1].
//! This prevents fragmentation where we might otherwise end up with both [ID, Location, Rotation]
//! and [ID, Rotation, Location] archetypes simply due to order of operations. Fragmentation is bad
//! as it would result in more archetypes with less entities in them, more memory overhead, and less
//! CPU cache utilization as a result when iterating over entities.
//!
//! By default the data structure is optimistic about reuse: unused archetypes are not removed in
//! anticipation that they will likely be reused in the future. This is often the right choice, as
//! the memory required is relatively small, but should you want to reduce memory clearCache() may
//! be used.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Archetype = @import("Archetype.zig");

const ArchetypeTree = @This();

/// The actual list of nodes
nodes: std.ArrayListUnmanaged(Node),

/// Scratch space used during add/remove/clearCache operations
buf: std.ArrayListUnmanaged(u32),

pub fn initCapacity(allocator: Allocator, capacity: usize) !ArchetypeTree {
    var nodes = try std.ArrayListUnmanaged(Node).initCapacity(allocator, capacity + 1);
    errdefer nodes.deinit(allocator);

    var buf = try std.ArrayListUnmanaged(u32).initCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    var tree = ArchetypeTree{
        .nodes = nodes,
        .buf = buf,
    };
    _ = try tree.insert(allocator, 0, 0); // root node
    return tree;
}

fn insert(tree: *ArchetypeTree, allocator: Allocator, parent_idx: u32, name: u32) !u32 {
    // TODO: expensive! maybe we should introduce child_idx?
    for (tree.nodes.items, 0..) |node, idx| {
        if (node.parent_idx == parent_idx and node.name == name) return @as(u32, @intCast(idx));
    }
    try tree.nodes.append(allocator, .{ .name = name, .parent_idx = parent_idx });
    return @as(u32, @intCast(tree.nodes.items.len - 1));
}

/// Returns a pointer to the node at the given index. Pointer invalidation rules are the same as the
/// underlying ArrayList: mutative operations to the tree which allocate may invalidate the pointer.
pub inline fn index(tree: *ArchetypeTree, idx: u32) *Node {
    return &tree.nodes.items[idx];
}

/// Adds a component name to the given archetype; returning the new archetype index.
pub fn add(tree: *ArchetypeTree, allocator: Allocator, archetype_idx: u32, name: u32) !u32 {
    // Example: inserting C into archetype [A, B, D, E, F]

    // Starting from our component F, walk up the chain of parents until we encounter the
    // insertion point B. Produce an inverted list [F, E, D, B]
    var next_idx: u32 = archetype_idx;
    tree.buf.clearRetainingCapacity();
    while (true) {
        try tree.buf.append(allocator, next_idx);
        if (next_idx == 0) break;
        var next = tree.index(next_idx);
        if (next.name == name) return archetype_idx; // already contains B
        if (next.name < name) break;
        next_idx = next.parent_idx;
    }
    var inv = tree.buf.items;

    // Begin producing our new chain, start with our ancestor B.
    var i = inv.len - 1;
    var new_idx = inv[i]; // B
    var inserted = false;
    while (i > 0) : (i -= 1) {
        // Insert [D, E, F] in order, and C in the right place.
        if (tree.index(inv[i - 1]).name > name) {
            // Insert C in order
            new_idx = try tree.insert(allocator, new_idx, name);
            inserted = true;
        }
        new_idx = try tree.insert(allocator, new_idx, tree.index(inv[i - 1]).name);
    }
    if (!inserted) {
        // C comes last then.
        new_idx = try tree.insert(allocator, new_idx, name);
    }
    return new_idx;
}

/// Adds a component name to the given archetype; returning the new archetype index.
pub fn remove(tree: *ArchetypeTree, allocator: Allocator, archetype_idx: u32, name: u32) !u32 {
    // Example: removing C from archetype [A, B, C, D, E, F]

    // Starting from our component F, walk up the chain of parents until we encounter the
    // removal parent B. Produce an inverted list [F, E, D, B]
    tree.buf.clearRetainingCapacity();
    var next_idx: u32 = archetype_idx;
    while (true) {
        try tree.buf.append(allocator, next_idx);
        if (next_idx == 0) break;
        var next = tree.index(next_idx);
        if (next.name < name) break;
        next_idx = next.parent_idx;
    }
    var inv = tree.buf.items;

    // Begin producing our new chain, start with our ancestor B.
    var i = inv.len - 1;
    var new_idx = inv[i]; // B
    while (i > 0) : (i -= 1) {
        // Insert [D, E, F] in order, and C in the right place.
        if (tree.index(inv[i - 1]).name == name) continue; // remove
        new_idx = try tree.insert(allocator, new_idx, tree.index(inv[i - 1]).name);
    }
    return new_idx;
}

/// Checks if the given archetype contain the given component name.
pub fn contains(tree: *ArchetypeTree, archetype_idx: u32, name: u32) bool {
    // Example: finding C in archetype [A, B, C, D, E, F]
    // Walk up the parent chain.
    var next_idx: u32 = archetype_idx;
    while (true) {
        const next = tree.index(next_idx);
        if (next.name == name or (next_idx == 0 and name == 0)) return true; // contains C
        if (next.name < name or next_idx == 0) break; // optimization: can't come before due to order
        next_idx = next.parent_idx;
    }
    return false;
}

/// clearCache clears caches (nodes without archetypes, as well as nodes with archetypes which have
/// zero entities.)
///
/// In practice, this means future use of the ECS will be slower - but it can be useful for reducing
/// immediate memory usage.
pub fn clearCache(tree: *ArchetypeTree, allocator: Allocator) void {
    tree.buf.clearRetainingCapacity();
    var retry = true;
    var start = true;
    while (retry) {
        start = false;
        retry = false;

        // Attempt to quickly remove any indexes that we wrote down previously in clearCacheIndex
        // for a quick retry. This is just an optimization to help us remove lengthy chains quicker.
        for (tree.buf.items) |retry_idx| {
            // If we remove a node, it may be possible to remove parent nodes that now no longer
            // have that node as a dependent.
            _ = tree.clearCacheIndex(allocator, retry_idx, true);
        }
        tree.buf.clearRetainingCapacity();

        // Walk in reverse-order to encounter leafs more frequently, which results in less retries.
        var i: u32 = @as(u32, @intCast(tree.nodes.items.len - 1));
        while (i > 0) : (i -= 1) {
            // If we remove a node, it may be possible to remove parent nodes that now no longer
            // have that node as a dependent.
            retry = retry or tree.clearCacheIndex(allocator, i, true);
        }
    }

    // Finally, release unused memory.
    tree.nodes.shrinkAndFree(allocator, tree.nodes.items.len);
    tree.buf.shrinkAndFree(allocator, 0);
}

fn clearCacheIndex(tree: *ArchetypeTree, allocator: Allocator, i: u32, retry: bool) bool {
    if (i == 0) return false; // root is never removed
    // If the node has an archetype, see if it has no entities and we can remove it,
    // otherwise we can't remove this node.
    if (tree.index(i).archetype) |*archetype| {
        if (archetype.len == 0) archetype.deinit(allocator) else return false;
    }

    // optimization: we can't remove this node; but it is a good candidate for a quick retry later
    // if we have capacity to hold onto it for later.
    if (retry and tree.buf.items.len < tree.buf.capacity) tree.buf.appendAssumeCapacity(i);

    // Does anyone depend on this node as a parent? If so, we can't remove it.
    for (tree.nodes.items) |other_node| {
        if (other_node.parent_idx == i) {
            return false; // we can't remove this node
        }
    }

    // Remove this node.
    for (tree.nodes.items) |*other_node| {
        if (other_node.parent_idx > i) other_node.parent_idx -= 1;
    }
    for (tree.buf.items) |*retry_idx| {
        if (retry_idx.* > i) retry_idx.* -= 1;
    }
    _ = tree.nodes.swapRemove(i);
    return true;
}

pub fn deinit(tree: *ArchetypeTree, allocator: Allocator) void {
    for (tree.nodes.items) |*node| if (node.archetype) |*v| v.deinit(allocator);
    tree.nodes.deinit(allocator);
    tree.buf.deinit(allocator);
}

pub const Node = struct {
    //// this node's name, an arbitrary unique identifier.
    name: u32,

    /// the parent node, or zero if the root.
    parent_idx: u32,

    /// this archetype
    archetype: ?Archetype = null,
};

test "add" {
    const allocator = testing.allocator;
    var tree = try ArchetypeTree.initCapacity(allocator, 10);
    defer tree.deinit(allocator);

    const component_id: u32 = 0;
    const component_loc: u32 = 1;
    const component_rot: u32 = 2;
    const component_name: u32 = 3;
    const component_not_exist: u32 = 4;

    // Archetype: [ID]
    const archetype_id = 0; // root archetype is always index 0
    try testing.expectEqual(component_id, tree.index(archetype_id).name);
    try testing.expectEqual(true, tree.contains(archetype_id, component_id));

    // Adding root component (ID) is no-op
    const archetype_id_id = try tree.add(allocator, archetype_id, component_id);
    try testing.expectEqual(component_id, tree.index(archetype_id_id).name);

    // Archetype: [ID, Location]
    const archetype_id_loc = try tree.add(allocator, archetype_id, component_loc);
    try testing.expectEqual(component_loc, tree.index(archetype_id_loc).name);
    try testing.expectEqual(true, tree.contains(archetype_id_loc, component_id));
    try testing.expectEqual(true, tree.contains(archetype_id_loc, component_loc));
    try testing.expectEqual(false, tree.contains(archetype_id_loc, component_not_exist));

    // Archetype: [ID, Location, Rotation]
    const archetype_id_loc_rot = try tree.add(allocator, archetype_id_loc, component_rot);
    try testing.expectEqual(component_rot, tree.index(archetype_id_loc_rot).name);

    // Verify order-of-operations independence.
    var unordered: u32 = 0;
    unordered = try tree.add(allocator, unordered, component_loc);
    unordered = try tree.add(allocator, unordered, component_rot);
    unordered = try tree.add(allocator, unordered, component_name);
    try testing.expectEqual(component_name, tree.index(unordered).name);
    unordered = 0;
    unordered = try tree.add(allocator, unordered, component_rot);
    unordered = try tree.add(allocator, unordered, component_loc);
    unordered = try tree.add(allocator, unordered, component_name);
    try testing.expectEqual(component_name, tree.index(unordered).name);
}

test "remove" {
    const allocator = testing.allocator;
    var tree = try ArchetypeTree.initCapacity(allocator, 10);
    defer tree.deinit(allocator);

    const component_id: u32 = 0;
    const component_loc: u32 = 1;
    const component_rot: u32 = 2;
    const component_name: u32 = 3;
    const component_not_exist: u32 = 4;

    // [ID, Location, Rotation, Name]
    var archetype: u32 = 0;
    archetype = try tree.add(allocator, archetype, component_loc);
    archetype = try tree.add(allocator, archetype, component_rot);
    archetype = try tree.add(allocator, archetype, component_name);
    try testing.expectEqual(component_name, tree.index(archetype).name);

    // Removing a non-existant component is no-op.
    var tmp: u32 = archetype;
    tmp = try tree.remove(allocator, tmp, component_not_exist);
    try testing.expectEqual(component_name, tree.index(tmp).name);

    // Removing a root component (ID) is no-op.
    tmp = archetype;
    tmp = try tree.remove(allocator, tmp, component_id);
    try testing.expectEqual(component_name, tree.index(tmp).name);
    tmp = 0;
    tmp = try tree.remove(allocator, tmp, component_id);
    try testing.expectEqual(component_id, tree.index(tmp).name);

    // Ordered removal
    tmp = archetype;
    tmp = try tree.remove(allocator, tmp, component_name);
    try testing.expectEqual(component_rot, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_rot);
    try testing.expectEqual(component_loc, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_loc);
    try testing.expectEqual(component_id, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_id);
    try testing.expectEqual(component_id, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_not_exist);
    try testing.expectEqual(component_id, tree.index(tmp).name);

    try testing.expectEqual(true, tree.contains(tmp, component_id));
    try testing.expectEqual(false, tree.contains(tmp, component_name));
    try testing.expectEqual(false, tree.contains(tmp, component_rot));
    try testing.expectEqual(false, tree.contains(tmp, component_loc));
    try testing.expectEqual(false, tree.contains(tmp, component_not_exist));

    // Unordered removal
    tmp = archetype;
    tmp = try tree.remove(allocator, tmp, component_rot);
    try testing.expectEqual(component_name, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_loc);
    try testing.expectEqual(component_name, tree.index(tmp).name);
    tmp = try tree.remove(allocator, tmp, component_name);
    try testing.expectEqual(component_id, tree.index(tmp).name);
}

test "clearCache" {
    const allocator = testing.allocator;
    var tree = try ArchetypeTree.initCapacity(allocator, 10);
    defer tree.deinit(allocator);

    const component_id: u32 = 0;
    _ = component_id;
    const component_loc: u32 = 1;
    const component_rot: u32 = 2;
    const component_name: u32 = 3;
    const component_not_exist: u32 = 4;
    _ = component_not_exist;

    // [ID, Location, Rotation, Name]
    var archetype: u32 = 0;
    archetype = try tree.add(allocator, archetype, component_loc);
    const archetype_loc = archetype;
    archetype = try tree.add(allocator, archetype, component_rot);
    archetype = try tree.add(allocator, archetype, component_name);
    try testing.expectEqual(component_name, tree.index(archetype).name);

    // Make [ID, Location, Rotation, Name] archetype in-use
    tree.index(archetype).archetype = std.mem.zeroes(Archetype); // in use
    tree.index(archetype).archetype.?.len = 10;
    try testing.expectEqual(@as(usize, 4), tree.nodes.items.len);

    // Clearing cache doesn't remove parents that are needed
    tree.clearCache(allocator);
    try testing.expectEqual(@as(usize, 4), tree.nodes.items.len);

    // in use: [ID, Location]
    // not in use: [ID, Location, Rotation, Name]
    tree.index(archetype).archetype = null;
    tree.index(archetype_loc).archetype = std.mem.zeroes(Archetype);
    tree.index(archetype_loc).archetype.?.len = 10;
    tree.clearCache(allocator);
    try testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
}
