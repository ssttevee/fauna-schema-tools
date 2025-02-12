const std = @import("std");
const fauna = @import("fauna");

const Sha1 = std.crypto.hash.Sha1;

const FunctionInfo = struct {
    ast_node: *const fauna.SchemaDefinition.Function,

    /// Map of func names to references to their locations in the AST that may
    //  be used to update the names.
    dependencies: std.StringArrayHashMap([]const *fauna.TextNode),

    fn deinit(self: *FunctionInfo, allocator: std.mem.Allocator) void {
        // don't need to free the keys because the are borrowed
        for (self.dependencies.values()) |refs| {
            allocator.free(refs);
        }

        self.dependencies.deinit();

        self.* = undefined;
    }

    fn updateDependencyNames(self: FunctionInfo, allocator: std.mem.Allocator, mangled_func_names: std.StringHashMap([]const u8)) !void {
        // references must be updated to mangled names before generating the
        // hash so that changes in dependencies are propagated.
        for (self.dependencies.keys(), self.dependencies.values()) |referenced_func_name, references| {
            const mangled_name = mangled_func_names.get(referenced_func_name).?;
            for (references) |ref| {
                // must use tree's allocator to free and dupe
                allocator.free(ref.text);
                ref.text = try allocator.dupe(u8, mangled_name);
            }
        }

        // ownership of original name is transferred to `mangled_func_names`
        // and ownership of `mangled_name` is transferred to the tree.
        @constCast(self.ast_node).name.text = mangled_func_names.get(self.ast_node.name.text).?;
    }
};

pub const LinkFunctionsResult = struct {
    allocator: std.mem.Allocator,
    names: std.StringHashMapUnmanaged([]const u8),
    missing: [][]const u8,

    pub fn deinit(self: LinkFunctionsResult) void {
        var original_name_iterator = self.names.keyIterator();
        while (original_name_iterator.next()) |original_name| {
            self.allocator.free(original_name.*);
        }

        @constCast(&self.names).deinit(self.allocator);

        for (self.missing) |name| {
            self.allocator.free(name);
        }

        self.allocator.free(self.missing);
    }
};

/// This function "mangles" the names of all functions using the hash of the
/// canonical representation while maintaining reference integrity.
///
/// Returns a map of original func names to mangled func names.
///
/// The returned hashmap owns the pointers to the keys, but not the values,
/// which are owned by the AST.
pub fn linkFunctions(allocator: std.mem.Allocator, tree: fauna.SchemaTree) !LinkFunctionsResult {
    var funcs, const missing = try findFunctionDependencies(allocator, tree);
    defer {
        for (funcs.values()) |*info| {
            info.deinit(allocator);
        }

        funcs.deinit();
    }

    errdefer {
        for (missing) |name| {
            allocator.free(name);
        }

        allocator.free(missing);
    }

    // NOTE: Mangled names must be allocated with the tree's allocator in case a
    //       different allocator is used for the AST. Likewise, original names
    //       must also be freed using the tree's allocator.

    // map of original func names -> mangled func names
    var mangled_func_names = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        // Original names should have been all swapped out for mangled names in
        // the AST, so free original names but not the mangled names.
        var original_name_iterator = mangled_func_names.keyIterator();
        while (original_name_iterator.next()) |original_name| {
            tree.allocator.free(original_name.*);
        }

        mangled_func_names.deinit();
    }

    try mangled_func_names.ensureTotalCapacity(@intCast(funcs.count()));

    var unlinked_funcs = try std.StringArrayHashMapUnmanaged(void).init(allocator, funcs.keys(), &.{});
    defer unlinked_funcs.deinit(allocator);

    while (unlinked_funcs.count() > 0) {
        var linkable_funcs = try std.ArrayList([]const u8).initCapacity(allocator, unlinked_funcs.count());
        defer linkable_funcs.deinit();

        for (unlinked_funcs.keys()) |func_name| {
            const has_reference_to_unlinked_func = blk: {
                for (funcs.get(func_name).?.dependencies.keys()) |dependent_func_name| {
                    if (!mangled_func_names.contains(dependent_func_name)) {
                        break :blk true;
                    }
                }

                break :blk false;
            };

            if (!has_reference_to_unlinked_func) {
                linkable_funcs.appendAssumeCapacity(func_name);
            }
        }

        for (linkable_funcs.items) |original_name| {
            const func = funcs.get(original_name).?;

            const mangled_name = try std.fmt.allocPrint(tree.allocator, "{s}_{s}", .{
                original_name,
                generateFunctionsHash(&.{original_name}, funcs),
            });

            mangled_func_names.putAssumeCapacityNoClobber(original_name, mangled_name);

            try func.updateDependencyNames(tree.allocator, mangled_func_names);

            _ = unlinked_funcs.swapRemove(original_name);
        }

        if (unlinked_funcs.count() == 0) {
            // all functions are linked!
            break;
        }

        if (linkable_funcs.items.len > 0) {
            // keep trying to linking non-circular
            continue;
        }

        // there are probably circular dependencies
        const cycles = try findCycles(allocator, unlinked_funcs, funcs);
        defer {
            for (cycles) |cycle| {
                allocator.free(cycle);
            }

            allocator.free(cycles);
        }

        std.debug.assert(cycles.len != 0);

        for (cycles) |cycle| {
            const hash = generateFunctionsHash(cycle, funcs);

            // mangled names must be set prior to updating the refs so that self
            // references are possible.
            for (cycle) |original_name| {
                const mangled_name = try std.fmt.allocPrint(tree.allocator, "{s}_{s}", .{
                    original_name,
                    hash,
                });

                mangled_func_names.putAssumeCapacityNoClobber(
                    original_name,
                    mangled_name,
                );
            }

            for (cycle) |func_name| {
                try funcs.get(func_name).?.updateDependencyNames(tree.allocator, mangled_func_names);

                _ = unlinked_funcs.swapRemove(func_name);
            }
        }
    }

    return .{
        .allocator = allocator,
        .names = mangled_func_names.unmanaged,
        .missing = missing,
    };
}

const CycleVisitor = struct {
    allocator: std.mem.Allocator,

    path: std.ArrayListUnmanaged([]const u8),
    visited: std.StringArrayHashMapUnmanaged(void),

    fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
        var visited = try std.StringArrayHashMapUnmanaged(void).init(allocator, &.{}, &.{});
        try visited.ensureTotalCapacity(allocator, capacity);
        return .{
            .allocator = allocator,
            .path = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, capacity),
            .visited = visited,
        };
    }

    fn deinit(self: *@This()) void {
        self.path.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.* = undefined;
    }

    // node for a crude backwards linked list
    const Node = struct {
        func_name: []const u8,
        parent_node: ?*const Node,
    };

    fn visit(
        self: *@This(),
        allocator: std.mem.Allocator,
        func_name: []const u8,
        funcs: std.StringArrayHashMap(FunctionInfo),
        cycles: *std.ArrayList([][]const u8),
    ) !void {
        if (self.visited.contains(func_name)) {
            return;
        }

        self.visited.putAssumeCapacityNoClobber(func_name, {});

        self.path.appendAssumeCapacity(func_name);
        defer self.path.items.len -= 1;

        for (funcs.get(func_name).?.dependencies.keys()) |dependency| {
            const match_index: ?usize = blk: {
                for (self.path.items, 0..) |path_item, i| {
                    if (std.mem.eql(u8, dependency, path_item)) {
                        break :blk i;
                    }
                }

                break :blk null;
            };

            if (match_index) |i| {
                try cycles.append(try allocator.dupe([]const u8, self.path.items[i..]));
            } else {
                try self.visit(allocator, dependency, funcs, cycles);
            }
        }
    }
};

fn findCycles(
    allocator: std.mem.Allocator,
    participating_funcs: std.StringArrayHashMapUnmanaged(void),
    funcs: std.StringArrayHashMap(FunctionInfo),
) ![][][]const u8 {
    var visitor = try CycleVisitor.init(allocator, participating_funcs.count());
    defer visitor.deinit();

    var cycles = std.ArrayList([][]const u8).init(allocator);
    defer {
        for (cycles.items) |cycle| {
            allocator.free(cycle);
        }

        cycles.deinit();
    }

    for (participating_funcs.keys()) |func_name| {
        try visitor.visit(allocator, func_name, funcs, &cycles);
    }

    while (true) {
        var merged_cycles = try std.ArrayList([][]const u8).initCapacity(allocator, cycles.items.len);
        defer {
            for (merged_cycles.items) |cycle| {
                allocator.free(cycle);
            }

            merged_cycles.deinit();
        }

        cycles: for (cycles.items) |cycle| {
            const overlapped_cycle_index: ?usize = blk: {
                for (merged_cycles.items, 0..) |merged_cycle, i| {
                    for (merged_cycle) |a| {
                        for (cycle) |b| {
                            if (std.mem.eql(u8, a, b)) {
                                break :blk i;
                            }
                        }
                    }
                }

                break :blk null;
            };

            if (overlapped_cycle_index) |i| {
                var deduped = std.StringArrayHashMapUnmanaged(void){};
                defer deduped.deinit(allocator);

                try deduped.ensureTotalCapacity(allocator, merged_cycles.items[i].len + cycle.len - 1);

                for (merged_cycles.items[i]) |func_name| {
                    deduped.putAssumeCapacity(func_name, {});
                }

                for (cycle) |func_name| {
                    deduped.putAssumeCapacity(func_name, {});
                }

                allocator.free(merged_cycles.items[i]);
                merged_cycles.items[i] = try allocator.dupe([]const u8, deduped.keys());

                continue :cycles;
            } else {
                merged_cycles.appendAssumeCapacity(try allocator.dupe([]const u8, cycle));
            }
        }

        if (merged_cycles.items.len == cycles.items.len) {
            break;
        }

        // swap the lists so that the old list will be cleaned up
        const saved = cycles;
        cycles = merged_cycles;
        merged_cycles = saved;
    }

    return cycles.toOwnedSlice();
}

fn HashWriter(comptime T: type) type {
    return std.io.Writer(
        *T,
        error{},
        struct {
            fn writeFn(hash: *T, bytes: []const u8) error{}!usize {
                hash.update(bytes);
                return bytes.len;
            }
        }.writeFn,
    );
}

fn generateFunctionsHash(func_names: []const []const u8, funcs: std.StringArrayHashMap(FunctionInfo)) [Sha1.digest_length * 2]u8 {
    var hasher = Sha1.init(.{});
    for (func_names) |func_name| {
        funcs.get(func_name).?.ast_node.printCanonical((HashWriter(Sha1){ .context = &hasher }).any(), "  ") catch unreachable;
    }

    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// Returns a map of function names to maps of references and a list of missing function names.
///
/// All returned pointers, not including the hashmap and reference slice, are
/// owned by the tree.
fn findFunctionDependencies(allocator: std.mem.Allocator, tree: fauna.SchemaTree) !std.meta.Tuple(&.{ std.StringArrayHashMap(FunctionInfo), [][]const u8 }) {
    var funcs = std.StringHashMap(*fauna.SchemaDefinition.Function).init(allocator);
    // both keys and values are borrowed references
    defer funcs.deinit();

    for (tree.declarations.?) |*elem| {
        switch (elem.*) {
            .function => |*func| {
                // use the ptrs from the tree because the tree will outlive the hashmap
                try funcs.put(func.name.text, func);
            },
            else => {},
        }
    }

    var all_funcs_deps = std.StringArrayHashMap(FunctionInfo).init(allocator);
    errdefer {
        // don't need to free the keys because the are borrowed
        for (all_funcs_deps.values()) |*info| {
            info.deinit(allocator);
        }

        all_funcs_deps.deinit();
    }

    try all_funcs_deps.ensureTotalCapacity(funcs.count());

    var missing_func_names = std.StringArrayHashMap(void).init(allocator);
    defer missing_func_names.deinit();
    errdefer {
        for (missing_func_names.keys()) |name| {
            allocator.free(name);
        }
    }

    var func_it = funcs.valueIterator();
    while (func_it.next()) |func| {
        var func_deps = std.StringHashMap(std.ArrayListUnmanaged(*fauna.TextNode)).init(allocator);
        defer {
            var it = func_deps.valueIterator();
            while (it.next()) |refs| {
                refs.deinit(allocator);
            }

            func_deps.deinit();
        }

        var walker = func.*.walkBody(allocator);
        defer walker.deinit();

        while (try walker.next()) |expr| {
            if (expr.* != .invocation or expr.invocation.function.* != .identifier) {
                continue;
            }

            const ident = &expr.invocation.function.identifier;
            const func_name = ident.text;

            if (funcs.get(func_name)) |func_info| {
                const result = try func_deps.getOrPutValue(func_info.name.text, .{});
                try result.value_ptr.append(allocator, @constCast(ident));
            } else {
                const gop = try missing_func_names.getOrPut(func_name);
                if (!gop.found_existing) {
                    errdefer _ = missing_func_names.pop();
                    gop.key_ptr.* = try allocator.dupe(u8, func_name);
                }
            }
        }

        all_funcs_deps.putAssumeCapacityNoClobber(func.*.name.text, blk: {
            var finalized_deps = std.StringArrayHashMap([]const *fauna.TextNode).init(allocator);
            errdefer {
                for (finalized_deps.values()) |refs| {
                    allocator.free(refs);
                }

                finalized_deps.deinit();
            }

            try finalized_deps.ensureTotalCapacity(func_deps.count());

            var it = func_deps.iterator();
            while (it.next()) |refs| {
                finalized_deps.putAssumeCapacity(refs.key_ptr.*, try refs.value_ptr.toOwnedSlice(allocator));
            }

            break :blk .{
                .ast_node = func.*,
                .dependencies = finalized_deps,
            };
        });
    }

    return .{
        all_funcs_deps,
        try allocator.dupe([]const u8, missing_func_names.keys()),
    };
}

/// Returns a list of missing function names
///
/// Expects a map of original func names to mangled func names. That is the same as the return value of `linkFunctions`.
pub fn updatePredicateFunctionReferences(allocator: std.mem.Allocator, tree: fauna.SchemaTree, mangled_func_names: std.StringHashMapUnmanaged([]const u8)) ![][]const u8 {
    var missing_func_names = std.StringArrayHashMap(void).init(allocator);
    defer missing_func_names.deinit();
    errdefer {
        for (missing_func_names.keys()) |name| {
            allocator.free(name);
        }
    }

    var maybe_it = tree.walkPredicates();
    if (maybe_it) |*pred_it| {
        while (pred_it.next()) |pred| {
            var it = pred.walk(allocator);
            defer it.deinit();

            while (try it.next()) |expr| {
                if (expr.* != .invocation or expr.invocation.function.* != .identifier) {
                    continue;
                }

                const ident = &expr.invocation.function.identifier;
                const func_name = ident.text;

                if (mangled_func_names.get(func_name)) |mangled_name| {
                    tree.allocator.free(func_name);
                    @constCast(ident).text = try tree.allocator.dupe(u8, mangled_name);
                } else {
                    const gop = try missing_func_names.getOrPut(func_name);
                    if (!gop.found_existing) {
                        errdefer _ = missing_func_names.pop();
                        gop.key_ptr.* = try allocator.dupe(u8, func_name);
                    }
                }
            }
        }
    }

    if (tree.declarations) |decls| {
        for (decls) |decl| {
            if (decl != .role) {
                continue;
            }

            if (decl.role.members) |members| {
                for (members) |*member| {
                    if (member.* != .privileges) {
                        continue;
                    }

                    if (mangled_func_names.get(member.privileges.resource.text)) |mangled_name| {
                        tree.allocator.free(member.privileges.resource.text);
                        @constCast(member).privileges.resource.text = try tree.allocator.dupe(u8, mangled_name);
                    }
                }
            }
        }
    }

    return try allocator.dupe([]const u8, missing_func_names.keys());
}
