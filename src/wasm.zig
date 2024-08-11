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

fn linkFunctionsInternal(tree: fauna.SchemaTree) !void {
    return linker.linkFunctions(std.heap.wasm_allocator, tree);
}

pub fn linkFunctions(tree: fauna.SchemaTree) bool {
    linkFunctionsInternal(tree) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return false;
    };
    return true;
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

fn parseSchemaTreeInternal(schema: []const u8) !fauna.SchemaTree {
    var stream = std.io.fixedBufferStream(schema);

    return try fauna.SchemaTree.parse(std.heap.wasm_allocator, stream.reader().any(), "memory");
}

pub fn parseSchemaTree(schema: []const u8) ?fauna.SchemaTree {
    return parseSchemaTreeInternal(schema) catch |err| {
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
