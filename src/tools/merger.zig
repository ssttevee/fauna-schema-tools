const std = @import("std");
const fauna = @import("fauna");

pub fn mergeRoles(allocator: std.mem.Allocator, tree: *fauna.SchemaTree) !void {
    const old_decls = tree.declarations orelse return;

    var decls = try std.ArrayList(fauna.SchemaDefinition).initCapacity(tree.allocator, old_decls.len);
    defer {
        // in the case of an error, only the role members slice need to be freed,
        // successful execution should result in an empty list
        for (decls.items) |decl| {
            if (decl == .role) {
                tree.allocator.free(decl.role.members.?);
            }
        }

        decls.deinit();
    }

    var roles = std.StringArrayHashMap(std.ArrayListUnmanaged(fauna.SchemaDefinition.Role.Member)).init(allocator);
    defer {
        for (roles.values()) |*members| {
            members.deinit(tree.allocator);
        }

        roles.deinit();
    }

    try roles.ensureTotalCapacity(decls.capacity);

    // keep a list of old member slices to free at the end to maintain the integrity of the tree on error
    var old_members_slices = try std.ArrayList([]const fauna.SchemaDefinition.Role.Member).initCapacity(allocator, decls.capacity);
    defer old_members_slices.deinit();

    for (old_decls) |decl| {
        switch (decl) {
            .role => |role| {
                // use the ptrs from the tree because the tree will outlive the hashmap
                const result = try roles.getOrPut(role.name);
                if (!result.found_existing) {
                    result.key_ptr.* = role.name;
                    result.value_ptr.* = .{};
                } else {
                    tree.allocator.free(role.name);
                }

                if (role.members) |members| {
                    try result.value_ptr.appendSlice(tree.allocator, members);

                    // keep this to free later
                    old_members_slices.appendAssumeCapacity(members);
                }
            },
            else => {
                decls.appendAssumeCapacity(decl);
            },
        }
    }

    for (roles.keys(), roles.values()) |role_name, *members| {
        decls.appendAssumeCapacity(.{
            .role = .{
                .name = role_name,
                .members = try members.toOwnedSlice(tree.allocator),
            },
        });
    }

    tree.declarations = try decls.toOwnedSlice();
    tree.allocator.free(old_decls);

    // it's finally safe to free the old members slices
    for (old_members_slices.items) |members_slice| {
        tree.allocator.free(members_slice);
    }
}
