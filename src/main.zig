const std = @import("std");
const fauna = @import("fauna");
// const dts = @import("tools/dts.zig");
const linker = @import("tools/linker.zig");
const merger = @import("tools/merger.zig");

const function_files = [_][]const u8{
    "functions/getFolderAncestors.fsl",
    "functions/getUserFolderCollaborator.fsl",
    "functions/getUserFolderPrivileges.fsl",
    "functions/getUserTeamMember.fsl",
    "functions/getUserTeamPrivileges.fsl",
    "functions/matchPrivilegeRequest.fsl",
    "functions/normalizeArrayWithDefaults.fsl",
    "functions/userHasFolderPrivileges.fsl",
    "functions/userHasTeamPrivileges.fsl",
    "functions/userIsDocumentOwner.fsl",
    "functions/userIsTeamMember.fsl",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();

    const allocator = gpa.allocator();

    var ftrees: [function_files.len]fauna.SchemaTree = undefined;
    for (function_files, 0..) |file, i| {
        std.debug.print("parsing {s}\n", .{file});
        ftrees[i] = try fauna.SchemaTree.parseFile(allocator, file);
    }

    var tree = try merger.mergeSchemas(allocator, &ftrees);
    defer tree.deinit();

    var result = try linker.linkFunctions(allocator, tree);
    defer result.deinit();

    try merger.mergeRoles(allocator, &tree);

    const stdout = std.io.getStdOut();
    defer stdout.close();

    const w = stdout.writer();
    try tree.printCanonical(w.any());
    // try dts.printTypescriptDefinitions(w, tree);
}
