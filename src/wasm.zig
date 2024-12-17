const std = @import("std");
const fauna = @import("fauna");
const zbind = @import("zbind");

const dts = @import("tools/dts.zig");
const linker = @import("tools/linker.zig");
const merger = @import("tools/merger.zig");

fn generateTypescriptDefinitionsInternal(tree: fauna.SchemaTree) ![]const u8 {
    var buf = std.ArrayList(u8).init(std.heap.wasm_allocator);
    defer buf.deinit();

    try dts.printTypescriptDefinitions(buf.writer().any(), tree);

    return try buf.toOwnedSlice();
}

pub fn generateTypescriptDefinitions(tree: fauna.SchemaTree) ?[]const u8 {
    return generateTypescriptDefinitionsInternal(tree) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

fn printCanonicalTreeInternal(allocator: std.mem.Allocator, tree: fauna.SchemaTree, source_map_file: ?[]const u8, mangled_names_map_json: ?[]const u8, sources_json: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var source_map_writer: ?fauna.SourceMapWriter = null;
    defer if (source_map_writer) |*smw| {
        for (smw.name_map.keys(), smw.name_map.values()) |key, value| {
            allocator.free(key);
            allocator.free(value);
        }

        smw.name_map.deinit(allocator);

        smw.deinit();
    };

    var w: std.io.AnyWriter = buf.writer().any();
    if (source_map_file) |filename| {
        source_map_writer = try fauna.SourceMapWriter.init(allocator, buf.writer().any(), filename, "");
        const smw = &source_map_writer.?;
        if (mangled_names_map_json) |json| {
            // The map returned by linkFunctions is a map of original func names -> mangled func names,
            // but the source map writer expects mangled func names -> original func names,
            // so the map must be inverted here.
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();

            if (parsed.value == .object) {
                for (parsed.value.object.keys(), parsed.value.object.values()) |key, value| {
                    if (value != .string) {
                        std.log.warn("json name map field \"{s}\" is expected to be a string, but found a {s}...", .{ key, @tagName(value) });
                        continue;
                    }

                    const result = try smw.name_map.getOrPut(allocator, value.string);
                    if (result.found_existing) {
                        std.log.warn("ignoring duplicate name: {d}", .{value.string});
                        continue;
                    }

                    result.key_ptr.* = try allocator.dupe(u8, value.string);
                    result.value_ptr.* = try allocator.dupe(u8, key);
                }
            } else {
                std.log.warn("ignoring non-object mangled name map", .{});
            }
        }

        w = smw.anyWriter();
    }

    try tree.printCanonical(w);

    if (source_map_writer) |*smw| {
        if (sources_json) |json| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();

            if (parsed.value == .object) {
                for (parsed.value.object.keys(), parsed.value.object.values()) |key, value| {
                    if (value != .string) {
                        std.log.warn("sources field \"{s}\" is expected to be a string, but found a {s}...", .{ key, @tagName(value) });
                        continue;
                    }

                    if (smw.state.generator.sources.getEntry(key)) |entry| {
                        entry.value_ptr.* = try allocator.dupe(u8, value.string);
                    }
                }
            } else {
                std.log.warn("ignoring non-object sources", .{});
            }
        }

        try smw.writeInlineSourceMap();
    }

    return try buf.toOwnedSlice();
}

pub fn printCanonicalTree(tree: fauna.SchemaTree, source_map_file: ?[]const u8, mangled_names_map_json: ?[]const u8, sources_json: ?[]const u8) ?[]const u8 {
    return printCanonicalTreeInternal(std.heap.wasm_allocator, tree, source_map_file, mangled_names_map_json, sources_json) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

fn linkFunctionsInternal(tree: fauna.SchemaTree) ![]const u8 {
    var mangled_func_names = try linker.linkFunctions(std.heap.wasm_allocator, tree);
    defer {
        var original_name_iterator = mangled_func_names.keyIterator();
        while (original_name_iterator.next()) |original_name| {
            tree.allocator.free(original_name.*);
        }

        mangled_func_names.deinit();
    }

    try linker.updatePredicateFunctionReferences(std.heap.wasm_allocator, tree, mangled_func_names);

    var out = std.ArrayList(u8).init(std.heap.wasm_allocator);
    defer out.deinit();

    {
        var s = std.json.writeStream(out.writer(), .{});
        s.deinit();

        var it = mangled_func_names.iterator();
        try s.beginObject();
        while (it.next()) |entry| {
            try s.objectField(entry.key_ptr.*);
            try s.write(entry.value_ptr.*);
        }
        try s.endObject();
    }

    return out.toOwnedSlice();
}

pub fn linkFunctions(tree: fauna.SchemaTree) ?[]const u8 {
    return linkFunctionsInternal(tree) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

fn mergeRolesInternal(tree: *fauna.SchemaTree) !void {
    return merger.mergeRoles(std.heap.wasm_allocator, tree);
}

pub fn mergeRoles(tree: fauna.SchemaTree) ?fauna.SchemaTree {
    var copy = tree;
    mergeRolesInternal(&copy) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
    return copy;
}

fn mergeSchemasInternal(trees: []const fauna.SchemaTree) !fauna.SchemaTree {
    return merger.mergeSchemas(std.heap.wasm_allocator, trees);
}

pub fn mergeSchemas(a: fauna.SchemaTree, b: fauna.SchemaTree) ?fauna.SchemaTree {
    return mergeSchemasInternal(&.{ a, b }) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

pub fn sortSchemaTree(tree: fauna.SchemaTree) void {
    if (tree.declarations) |decls| {
        std.mem.sort(fauna.SchemaDefinition, decls, {}, (struct {
            fn lessThan(_: void, lhs: fauna.SchemaDefinition, rhs: fauna.SchemaDefinition) bool {
                return std.mem.lessThan(u8, @tagName(lhs), @tagName(rhs)) or std.mem.lessThan(u8, lhs.name(), rhs.name());
            }
        }).lessThan);
    }
}

fn filterSchemaTreeByTypeInternal(schema: fauna.SchemaTree, tag: std.meta.Tag(fauna.SchemaDefinition)) !fauna.SchemaTree {
    var new_decls = try std.ArrayList(fauna.SchemaDefinition).initCapacity(schema.allocator, (schema.declarations orelse &.{}).len);
    errdefer {
        for (new_decls.items) |decl| {
            decl.deinit(schema.allocator);
        }

        new_decls.deinit();
    }

    if (schema.declarations) |decls| {
        for (decls) |decl| {
            if (std.meta.activeTag(decl) == tag) {
                new_decls.appendAssumeCapacity(try decl.dupe(schema.allocator));
            }
        }
    }

    return .{
        .allocator = schema.allocator,
        .extras = try fauna.SharedPtr([]const u8).dupeSlice(schema.extras, schema.allocator),
        .declarations = try new_decls.toOwnedSlice(),
    };
}

pub fn filterSchemaTreeByType(schema: fauna.SchemaTree, decl_type: []const u8) ?fauna.SchemaTree {
    if (std.meta.stringToEnum(std.meta.Tag(fauna.SchemaDefinition), decl_type)) |tag| {
        return filterSchemaTreeByTypeInternal(schema, tag) catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            return null;
        };
    } else {
        std.debug.print("Error: invalid type {s} (valid types are access_provider, collection, role and function)\n", .{decl_type});
    }

    return null;
}

/// Remove a declaration from the tree, maintaining declaration order. The input tree becomes invalid the returned tree should be used in place of the old tree.
pub fn removeSchemaTreeDeclaration(tree: fauna.SchemaTree, decl_type: []const u8, decl_name: []const u8) fauna.SchemaTree {
    const tag = std.meta.stringToEnum(std.meta.Tag(fauna.SchemaDefinition), decl_type) orelse return tree;
    const decls = tree.declarations orelse return tree;
    const remove_index = blk: {
        for (decls, 0..) |decl, i| {
            if (std.meta.activeTag(decl) == tag and std.mem.eql(u8, decl.name(), decl_name)) {
                break :blk i;
            }
        }

        return tree;
    };

    decls[remove_index].deinit(tree.allocator);

    std.mem.copyForwards(fauna.SchemaDefinition, decls[remove_index..], decls[remove_index + 1 ..]);

    return .{
        .allocator = tree.allocator,
        .declarations = tree.allocator.realloc(decls, decls.len - 1) catch unreachable,
        .extras = tree.extras,
    };
}

/// Removes references to a resource from all role declarations.
pub fn removeSchemaTreeRolesResource(tree: fauna.SchemaTree, resource_name: []const u8) void {
    const decls = tree.declarations orelse return;
    for (decls) |*decl| {
        if (decl.* == .role) {
            var members: []fauna.SchemaDefinition.Role.Member = @constCast(decl.role.members orelse continue);
            defer decl.role.members = members;

            var i: usize = 0;
            while (i < members.len) {
                const member = members[i];
                if (member != .privileges) {
                    i += 1;
                    continue;
                }

                if (std.mem.eql(u8, member.privileges.resource.text, resource_name)) {
                    members[i].deinit(tree.allocator);
                    std.mem.copyForwards(fauna.SchemaDefinition.Role.Member, members[i..], members[i + 1 ..]);

                    members = tree.allocator.realloc(members, members.len - 1) catch unreachable;
                } else {
                    i += 1;
                }
            }
        }
    }
}

fn listSchemaTreeDeclarationsInternal(allocator: std.mem.Allocator, tree: fauna.SchemaTree) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var stream = std.json.writeStream(buf.writer(), .{});
    try stream.beginArray();
    if (tree.declarations) |decls| {
        for (decls) |decl| {
            try stream.beginObject();
            try stream.objectField("type");
            try stream.write(@tagName(decl));
            try stream.objectField("name");
            try stream.write(decl.name());

            if (decl == .role) {
                try stream.objectField("resources");
                try stream.beginArray();
                if (decl.role.members) |members| {
                    for (members) |member| {
                        if (member != .privileges) {
                            continue;
                        }

                        try stream.write(member.privileges.resource.text);
                    }
                }

                try stream.endArray();
            }

            try stream.endObject();
        }
    }

    try stream.endArray();

    return buf.toOwnedSlice();
}

pub fn listSchemaTreeDeclarations(tree: fauna.SchemaTree) ?[]const u8 {
    return listSchemaTreeDeclarationsInternal(std.heap.wasm_allocator, tree) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

pub fn getSchemaTreeLength(tree: fauna.SchemaTree) usize {
    if (tree.declarations) |decls| {
        return decls.len;
    }

    return 0;
}

fn parseSchemaTreeInternal(schema: []const u8, filename: ?[]const u8) !fauna.SchemaTree {
    var stream = std.io.fixedBufferStream(schema);

    return try fauna.SchemaTree.parse(std.heap.wasm_allocator, stream.reader().any(), filename orelse "memory");
}

pub fn parseSchemaTree(schema: []const u8, filename: ?[]const u8) ?fauna.SchemaTree {
    return parseSchemaTreeInternal(schema, filename) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

pub fn cloneSchemaTree(tree: fauna.SchemaTree) ?fauna.SchemaTree {
    return tree.dupe(std.heap.wasm_allocator) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return null;
    };
}

pub fn deinitSchemaTree(tree: fauna.SchemaTree) void {
    tree.deinit();
}

pub fn freeBytes(bytes: []const u8) void {
    std.heap.wasm_allocator.free(bytes);
}

// fn wasmLogger(
//     comptime message_level: std.log.Level,
//     comptime scope: @TypeOf(.enum_literal),
//     comptime format: []const u8,
//     args: anytype,
// ) void {
//     _ = message_level;
//     _ = scope;
//     _ = format;
//     _ = args;
// }

// pub const std_options = std.Options{
//     .logFn = wasmLogger,
// };

comptime {
    zbind.init(@This());
}
