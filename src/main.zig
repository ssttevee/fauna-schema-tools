const std = @import("std");
const fauna = @import("fauna");
// const dts = @import("tools/dts.zig");
const linker = @import("tools/linker.zig");
const merger = @import("tools/merger.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();

    const allocator = gpa.allocator();

    var tree = try fauna.SchemaTree.parseFile(allocator, "schema.fsl");
    defer tree.deinit();

    try linker.linkFunctions(allocator, tree);
    try merger.mergeRoles(allocator, &tree);

    const stdout = std.io.getStdOut();
    defer stdout.close();

    const w = stdout.writer();
    try tree.printCanonical(w.any());
    // try dts.printTypescriptDefinitions(w, tree);
}
