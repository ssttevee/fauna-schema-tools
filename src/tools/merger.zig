const std = @import("std");
const fauna = @import("fauna");
const builtin = @import("builtin");

pub fn mergeSchemas(allocator: std.mem.Allocator, trees: []const fauna.SchemaTree) !fauna.SchemaTree {
    if (trees.len == 0) {
        return .{ .allocator = allocator };
    }

    const total_len = blk: {
        var i: usize = 0;
        for (trees) |tree| {
            if (!builtin.cpu.arch.isWasm()) {
                // don't check for wasm because wasm allocator has undefined ptr
                std.debug.assert(tree.allocator.ptr == allocator.ptr);
            }
            std.debug.assert(tree.allocator.vtable == allocator.vtable);

            if (tree.declarations) |decls| {
                i += decls.len;
            }
        }

        break :blk i;
    };

    var all_decls = try allocator.alloc(fauna.SchemaDefinition, total_len);
    var i: usize = 0;
    for (trees) |tree| {
        if (tree.declarations) |decls| {
            for (decls) |decl| {
                all_decls[i] = decl;
                i += 1;
            }

            tree.allocator.free(decls);
        }
    }

    var extras_out = std.ArrayList(fauna.SharedPtr([]const u8)).init(allocator);
    defer extras_out.deinit();

    for (trees) |tree| {
        if (tree.extras) |extras| {
            try extras_out.appendSlice(extras);
            tree.allocator.free(extras);
        }
    }

    return .{
        .allocator = allocator,
        .declarations = all_decls,
        .extras = try extras_out.toOwnedSlice(),
    };
}

fn codeEquals(a_node: anytype, b_node: anytype) bool {
    const T = @TypeOf(a_node);
    std.debug.assert(T == @TypeOf(b_node));
    if (T == []const u8) {
        return std.mem.eql(u8, a_node, b_node);
    }

    switch (@typeInfo(T)) {
        .Enum => {
            return a_node == b_node;
        },
        .Optional => {
            return codeEquals(a_node.?, b_node.?);
        },
        .Struct => |struct_info| {
            inline for (struct_info.fields) |field_info| {
                if (field_info.type == ?fauna.Position or field_info.type == ?[]const fauna.Position or field_info.type == ?fauna.SourceLocation) {
                    continue;
                }

                if (!codeEquals(@field(a_node, field_info.name), @field(b_node, field_info.name))) {
                    return false;
                }
            }

            return true;
        },
        .Union => {
            const tag = std.meta.activeTag(a_node);
            if (tag != std.meta.activeTag(b_node)) {
                return false;
            }

            switch (tag) {
                inline else => |active_tag| {
                    return codeEquals(@field(a_node, @tagName(active_tag)), @field(b_node, @tagName(active_tag)));
                },
            }
        },
        .Pointer => |ptr_info| {
            switch (ptr_info.size) {
                .One => {
                    return codeEquals(a_node.*, b_node.*);
                },
                .Slice => {
                    const a_elems, const b_elems = blk: {
                        const info = @typeInfo(T);
                        if (info == .Optional) {
                            const child_info = @typeInfo(info.Optional.child);
                            std.debug.assert(child_info.Pointer.size == .Slice);
                            if (a_node == null and b_node == null) {
                                return true;
                            }

                            if ((a_node == null) != (b_node == null)) {
                                return false;
                            }

                            break :blk .{ a_node.?, b_node.? };
                        } else {
                            std.debug.assert(info.Pointer.size == .Slice);
                            break :blk .{ a_node, b_node };
                        }
                    };

                    if (a_elems.len != b_elems.len) {
                        return false;
                    }

                    for (0..a_elems.len) |i| {
                        if (!codeEquals(&a_elems[i], &b_elems[i])) {
                            return false;
                        }
                    }

                    return true;
                },
                else => {},
            }
        },
        else => {},
    }

    std.debug.panic("codeEquals is not supported for type {}", .{T});
}

fn combineRolePrivileges(allocator: std.mem.Allocator, a: *const fauna.SchemaDefinition.Role.Member.Privileges, b: *const fauna.SchemaDefinition.Role.Member.Privileges) !fauna.SchemaDefinition.Role.Member.Privileges {
    if (!std.mem.eql(u8, a.resource.text, b.resource.text)) {
        return error.NonMatchingResource;
    }

    var action_map = std.AutoArrayHashMap(fauna.SchemaDefinition.Role.Member.Privileges.Action.Action, fauna.SchemaDefinition.Role.Member.Privileges.Action).init(allocator);
    defer action_map.deinit();
    errdefer {
        for (action_map.values()) |*action| {
            action.deinit(allocator);
        }
    }

    var count: usize = 0;
    inline for (.{ a.actions, b.actions }) |maybe_actions| {
        if (maybe_actions) |actions| {
            try action_map.ensureUnusedCapacity(actions.len);
            count += actions.len;
            for (actions) |*action| {
                const res = action_map.getOrPutAssumeCapacity(action.action);
                if (!res.found_existing) {
                    res.key_ptr.* = action.action;
                    res.value_ptr.* = try action.dupe(allocator);
                } else if (!codeEquals(res.value_ptr, action)) {
                    return error.DuplicateAction;
                }
            }
        }
    }

    return .{
        .resource = try a.resource.dupe(allocator),
        .actions = try allocator.dupe(fauna.SchemaDefinition.Role.Member.Privileges.Action, action_map.values()),
    };
}

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

    var old_members = try std.ArrayList(fauna.SchemaDefinition.Role.Member).initCapacity(allocator, decls.capacity);
    defer old_members.deinit();

    for (old_decls) |decl| {
        switch (decl) {
            .role => |role| {
                // use the ptrs from the tree because the tree will outlive the hashmap
                const result = try roles.getOrPut(role.name.text);
                if (!result.found_existing) {
                    result.key_ptr.* = role.name.text;
                    result.value_ptr.* = .{};
                } else {
                    tree.allocator.free(role.name.text);
                }

                const role_members = result.value_ptr;
                if (role.members) |members| {
                    try role_members.ensureUnusedCapacity(tree.allocator, members.len);

                    // build a hashmap of privileges for deduplication (cannot be cached because references become invalid when arraylist is resized)
                    var privileges_map = std.StringHashMap(*fauna.SchemaDefinition.Role.Member.Privileges).init(tree.allocator);
                    try privileges_map.ensureTotalCapacity(role_members.capacity);
                    defer privileges_map.deinit();

                    // populate the map with the existing privileges
                    for (role_members.items) |*member| {
                        switch (member.*) {
                            .privileges => |*privileges| {
                                const res = privileges_map.getOrPutAssumeCapacity(privileges.resource.text);
                                std.debug.assert(!res.found_existing);
                                res.key_ptr.* = privileges.resource.text;
                                res.value_ptr.* = privileges;
                            },
                            else => {
                                // do nothing
                            },
                        }
                    }

                    for (members) |member| {
                        const member_ptr = role_members.addOneAssumeCapacity();
                        member_ptr.* = member;

                        if (member_ptr.* == .privileges) {
                            const res = privileges_map.getOrPutAssumeCapacity(member_ptr.privileges.resource.text);
                            if (res.found_existing) {
                                const combined_privilege = try combineRolePrivileges(tree.allocator, res.value_ptr.*, &member_ptr.privileges);
                                try old_members.append(.{ .privileges = res.value_ptr.*.* });
                                try old_members.append(.{ .privileges = member_ptr.privileges });
                                res.value_ptr.*.* = combined_privilege;

                                role_members.items.len -= 1;
                            } else {
                                res.key_ptr.* = member_ptr.privileges.resource.text;
                                res.value_ptr.* = &member_ptr.privileges;
                            }
                        }
                    }

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
                .name = .{ .text = role_name },
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

    for (old_members.items) |member| {
        member.deinit(tree.allocator);
    }
}
