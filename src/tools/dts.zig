const std = @import("std");
const testing = std.testing;

const fauna = @import("fauna");

fn isOptionalType(fql_type: fauna.FQLType) bool {
    switch (fql_type) {
        .optional => {
            return true;
        },
        .@"union" => |u| {
            if (u.lhs.* == .named and std.mem.eql(u8, u.lhs.named.text, "Null")) {
                return true;
            }

            if (u.rhs.* == .named and std.mem.eql(u8, u.rhs.named.text, "Null")) {
                return true;
            }

            return isOptionalType(u.lhs.*) or isOptionalType(u.rhs.*);
        },
        else => return false,
    }
}

fn printConvertedType(writer: anytype, fql_type: fauna.FQLType) @TypeOf(writer).Error!void {
    switch (fql_type) {
        .named => |identifier| {
            if (std.mem.eql(u8, identifier.text, "Null")) {
                try writer.writeAll("null");
            } else if (std.mem.eql(u8, identifier.text, "String")) {
                try writer.writeAll("string");
            } else if (std.mem.eql(u8, identifier.text, "Number")) {
                try writer.writeAll("number");
            } else if (std.mem.eql(u8, identifier.text, "Boolean")) {
                try writer.writeAll("boolean");
            } else if (std.mem.eql(u8, identifier.text, "Any")) {
                try writer.writeAll("any");
            } else if (std.mem.eql(u8, identifier.text, "Time")) {
                try writer.writeAll("import(\"fauna\").TimeStub");
            } else if (std.mem.eql(u8, identifier.text, "Bytes")) {
                try writer.writeAll("Uint8Array");
            } else if (std.mem.eql(u8, identifier.text, "Date")) {
                try writer.writeAll("import(\"fauna\").DateStub");
            } else {
                try writer.writeAll(identifier.text);
            }
        },
        .object => |obj| {
            if (obj.fields) |fields| {
                if (fields.len == 1 and fields[0].key == .wildcard) {
                    try writer.writeAll("Record<string, ");
                    try printConvertedType(writer, fields[0].type);
                    try writer.writeByte('>');
                } else {
                    try writer.writeAll("{ ");
                    for (fields, 0..) |field, i| {
                        if (i > 0) {
                            try writer.writeAll("; ");
                        }

                        switch (field.key) {
                            .wildcard => {
                                try writer.writeAll("[key: string]");
                            },
                            inline .string, .identifier => |s| {
                                try writer.writeAll(s.text);
                            },
                        }

                        const optional = isOptionalType(field.type);
                        if (optional) {
                            try writer.writeByte('?');
                        }

                        try writer.writeAll(": ");

                        try printConvertedType(writer, field.type);
                    }

                    try writer.writeAll(" }");
                }
            } else {
                try writer.writeAll("{}");
            }
        },
        .@"union" => |u| {
            try printConvertedType(writer, u.lhs.*);
            try writer.writeAll(" | ");
            try printConvertedType(writer, u.rhs.*);
        },
        .optional => |optional| {
            try printConvertedType(writer, optional.type.*);
            try writer.writeAll(" | null | undefined");
        },
        .template => |template| {
            if (std.mem.eql(u8, template.name.text, "Ref") and template.parameters != null and template.parameters.?.len == 1) {
                try writer.writeAll("import(\"fauna\").DocumentT<");
                try printConvertedType(writer, template.parameters.?[0]);
                try writer.writeByte('>');
                return;
            }

            try writer.writeAll(template.name.text);
            try writer.writeByte('<');
            if (template.parameters) |params| {
                for (params, 0..) |param, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }

                    try printConvertedType(writer, param);
                }
            }

            try writer.writeByte('>');
        },
        .tuple => |tuple| {
            try writer.writeByte('[');
            if (tuple.types) |types| {
                for (types, 0..) |tuple_type, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }

                    try printConvertedType(writer, tuple_type);
                }
            }

            try writer.writeByte(']');
        },
        inline .string_literal, .number_literal => |literal| {
            try writer.writeAll(literal.text);
        },
        .function => |function| {
            switch (function.parameters) {
                .short => |short| {
                    try printConvertedType(writer, short.*);
                },
                .long => |long| {
                    try writer.writeByte('(');
                    if (long.types) |types| {
                        for (types, 0..) |param_type, i| {
                            if (i > 0) {
                                try writer.writeAll(", ");
                            }
                            if (long.variadic and i == types.len - 1) {
                                try writer.writeAll("...");
                            }

                            try printConvertedType(writer, param_type);
                        }
                    }
                    try writer.writeByte(')');
                },
            }

            try writer.writeAll(" => ");

            try printConvertedType(writer, function.return_type.*);
        },
        .isolated => |isolated| {
            try writer.writeByte('(');
            try printConvertedType(writer, isolated.type.*);
            try writer.writeByte(')');
        },
    }
}

fn printTypescriptType(w: anytype, col: fauna.SchemaDefinition.Collection) !void {
    try std.fmt.format(w, "export type {s} = {{\n", .{col.name});

    var has_fields = false;
    if (col.members) |members| {
        for (members) |member| {
            if (!has_fields) {
                has_fields = member == .field;
            }

            switch (member) {
                inline .field, .computed_field => |field| {
                    try std.fmt.format(w, "    {s}", .{field.name});
                    if (@typeInfo(@TypeOf(field.type)) == .Optional) {
                        if (field.type) |field_type| {
                            const optional = isOptionalType(field_type);
                            if (optional) {
                                try w.writeByte('?');
                            }

                            try w.writeAll(": ");

                            try printConvertedType(w, field_type);
                        } else {
                            try std.fmt.format(w, ": any", .{});
                        }
                    } else {
                        const optional = isOptionalType(field.type);
                        if (optional) {
                            try w.writeByte('?');
                        }

                        try w.writeAll(": ");

                        try printConvertedType(w, field.type);
                    }

                    try std.fmt.format(w, ";\n", .{});
                },
                else => {},
            }
        }
    }

    if (!has_fields) {
        try std.fmt.format(w, "    [name: string]: any;\n", .{});
    }

    try std.fmt.format(w, "}}\n\n", .{});

    if (col.alias != null and col.alias.?.value == .identifier) {
        try std.fmt.format(w, "export type {s} = {s};\n\n", .{ col.alias.?.value.identifier.text, col.name });
    }
}

fn toCamelCase(buf: []u8, str: []const u8) ![]const u8 {
    var state: enum {
        between_words,
        in_word,
    } = .between_words;

    var i: usize = 0;
    for (str) |c| {
        switch (state) {
            .between_words => {
                if (std.ascii.isAlphanumeric(c)) {
                    if (i >= buf.len) {
                        return error.NoSpaceLeft;
                    }

                    buf[i] = std.ascii.toUpper(c);
                    i += 1;
                    state = .in_word;
                }
            },
            .in_word => {
                if (std.ascii.isAlphanumeric(c)) {
                    if (i >= buf.len) {
                        return error.NoSpaceLeft;
                    }

                    buf[i] = c;
                    i += 1;
                } else {
                    state = .between_words;
                }
            },
        }
    }

    return buf[0..i];
}

pub fn printTypescriptDefinitions(writer: anytype, tree: fauna.SchemaTree) !void {
    if (tree.declarations) |declarations| {
        for (declarations) |decl| {
            if (decl != .collection) {
                continue;
            }

            try printTypescriptType(writer, decl.collection);
        }

        try std.fmt.format(writer, "export enum CollectionName {{\n", .{});

        var buf: [64]u8 = undefined;
        for (declarations) |decl| {
            if (decl != .collection) {
                continue;
            }

            try std.fmt.format(writer, "    {s} = \"{s}\",\n", .{ try toCamelCase(&buf, decl.collection.name.text), decl.collection.name });
        }

        try std.fmt.format(writer, "}}\n\n", .{});
    }
}
