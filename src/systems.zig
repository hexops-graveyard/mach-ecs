const std = @import("std");
const mem = std.mem;
const StructField = std.builtin.Type.StructField;

const Entities = @import("entities.zig").Entities;
const Modules = @import("modules.zig").Modules;
const EntityID = @import("entities.zig").EntityID;

pub fn World(comptime mods: anytype) type {
    const modules = Modules(mods);

    return struct {
        allocator: mem.Allocator,
        entities: Entities(modules.components),
        mod: Mods(),

        const Self = @This();

        fn Mod(comptime module_tag: anytype) type {
            const State = @TypeOf(@field(@as(modules.State, undefined), @tagName(module_tag)));
            const components = @field(modules.components, @tagName(module_tag));
            return struct {
                state: State,

                /// Sets the named component to the specified value for the given entity,
                /// moving the entity from it's current archetype table to the new archetype
                /// table if required.
                pub inline fn set(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                    component: @field(components, @tagName(component_name)),
                ) !void {
                    const mod_ptr = @fieldParentPtr(Mods(), @tagName(module_tag), m);
                    const world = @fieldParentPtr(Self, "mod", mod_ptr);
                    try world.entities.setComponent(entity, module_tag, component_name, component);
                }

                /// gets the named component of the given type (which must be correct, otherwise undefined
                /// behavior will occur). Returns null if the component does not exist on the entity.
                pub inline fn get(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                ) ?@field(components, @tagName(component_name)) {
                    const mod_ptr = @fieldParentPtr(Mods(), @tagName(module_tag), m);
                    const world = @fieldParentPtr(Self, "mod", mod_ptr);
                    return world.entities.getComponent(entity, module_tag, component_name);
                }

                /// Removes the named component from the entity, or noop if it doesn't have such a component.
                pub inline fn remove(
                    m: *@This(),
                    entity: EntityID,
                    comptime component_name: std.meta.DeclEnum(components),
                ) !void {
                    const mod_ptr = @fieldParentPtr(Mods(), @tagName(module_tag), m);
                    const world = @fieldParentPtr(Self, "mod", mod_ptr);
                    try world.entities.removeComponent(entity, module_tag, component_name);
                }
            };
        }

        fn Mods() type {
            var fields: []const StructField = &[0]StructField{};
            inline for (modules.modules) |M| {
                fields = fields ++ [_]std.builtin.Type.StructField{.{
                    .name = @tagName(M.name),
                    .type = Mod(M.name),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Mod(M.name)),
                }};
            }
            return @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .is_tuple = false,
                    .fields = fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                },
            });
        }

        pub fn init(allocator: mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .entities = try Entities(modules.components).init(allocator),
                .mod = undefined,
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
