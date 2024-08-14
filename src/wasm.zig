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

fn printCanonicalTreeInternal(tree: fauna.SchemaTree) ![]const u8 {
    var buf = std.ArrayList(u8).init(std.heap.wasm_allocator);
    defer buf.deinit();

    try tree.printCanonical(buf.writer().any());

    return try buf.toOwnedSlice();
}

pub fn printCanonicalTree(tree: fauna.SchemaTree) ?[]const u8 {
    return printCanonicalTreeInternal(tree) catch |err| {
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
