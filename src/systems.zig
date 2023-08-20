const std = @import("std");
const mem = std.mem;

const Entities = @import("entities.zig").Entities;
const Modules = @import("modules.zig").Modules;
const EntityID = @import("entities.zig").EntityID;

pub fn World(comptime mods: anytype) type {
    const modules = Modules(mods);
    return struct {
        allocator: mem.Allocator,
        entities: Entities(modules.components),
        state: modules.State,

        const Self = @This();

        pub fn Module(comptime module_tag: anytype, comptime State: type) type {
            return struct {
                world: *Self,

                const components = @field(modules.components, @tagName(module_tag));

                /// Returns a pointer to the state struct of this module.
                pub inline fn state(m: @This()) *State {
                    return &@field(m.world.state, @tagName(module_tag));
                }

                /// Returns a pointer to the state struct of this module.
                pub inline fn initState(m: @This(), s: State) void {
                    m.state().* = s;
                }

                /// Sets the named component to the specified value for the given entity,
                /// moving the entity from it's current archetype table to the new archetype
                /// table if required.
                pub inline fn set(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                    component: @field(components, @tagName(component_name)),
                ) !void {
                    try m.world.entities.setComponent(entity, module_tag, component_name, component);
                }

                /// gets the named component of the given type (which must be correct, otherwise undefined
                /// behavior will occur). Returns null if the component does not exist on the entity.
                pub inline fn get(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                ) ?@field(components, @tagName(component_name)) {
                    return m.world.entities.getComponent(entity, module_tag, component_name);
                }

                /// Removes the named component from the entity, or noop if it doesn't have such a component.
                pub inline fn remove(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                ) !void {
                    try m.world.entities.removeComponent(entity, module_tag, component_name);
                }
            };
        }

        pub inline fn mod(world: *Self, comptime module_tag: anytype) Self.Module(
            module_tag,
            @TypeOf(@field(world.state, @tagName(module_tag))),
        ) {
            return .{ .world = world };
        }

        pub fn init(allocator: mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .entities = try Entities(modules.components).init(allocator),
                .state = undefined,
            };
        }

        pub fn deinit(world: *Self) void {
            world.entities.deinit();
        }

        /// Broadcasts an event to all modules that are subscribed to it.
        ///
        /// The message tag corresponds with the handler method name to be invoked. For example,
        /// if `send(.tick)` is invoked, all modules which declare a `pub fn init` will be invoked.
        ///
        /// Events sent by Mach itself, or the application itself, may be single words. To prevent
        /// name conflicts, events sent by modules provided by a library should prefix their events
        /// with their module name. For example, a module named `.ziglibs_imgui` should use event
        /// names like `.ziglibsImguiClick`, `.ziglibsImguiFoobar`.
        pub fn send(world: *Self, comptime msg_tag: anytype) !void {
            inline for (modules.modules) |M| {
                if (@hasDecl(M, @tagName(msg_tag))) {
                    const handler = @field(M, @tagName(msg_tag));
                    try handler(world);
                }
            }
        }

        /// Returns a new entity.
        pub inline fn newEntity(world: *Self) !EntityID {
            return try world.entities.new();
        }

        /// Removes an entity.
        pub inline fn removeEntity(world: *Self, entity: EntityID) !void {
            try world.entities.removeEntity(entity);
        }
    };
}
