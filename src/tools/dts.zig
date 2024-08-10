const std = @import("std");
const fauna = @import("fauna");

fn isOptionalType(fql_type: fauna.FQLType) bool {
    switch (fql_type) {
        .optional => {
            return true;
        },
        .@"union" => |u| {
            if (u.lhs.* == .named and std.mem.eql(u8, u.lhs.named, "Null")) {
                return true;
            }

            if (u.rhs.* == .named and std.mem.eql(u8, u.rhs.named, "Null")) {
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
            if (std.mem.eql(u8, identifier, "Null")) {
                try writer.writeAll("null");
            } else if (std.mem.eql(u8, identifier, "String")) {
                try writer.writeAll("string");
            } else if (std.mem.eql(u8, identifier, "Number")) {
                try writer.writeAll("number");
            } else if (std.mem.eql(u8, identifier, "Boolean")) {
                try writer.writeAll("boolean");
            } else if (std.mem.eql(u8, identifier, "Any")) {
                try writer.writeAll("any");
            } else if (std.mem.eql(u8, identifier, "Time")) {
                try writer.writeAll("import(\"fauna\").FaunaTime");
            } else if (std.mem.eql(u8, identifier, "Bytes")) {
                try writer.writeAll("import(\"fauna\").Bytes");
            } else if (std.mem.eql(u8, identifier, "Date")) {
                try writer.writeAll("import(\"fauna\").FaunaDate");
            } else {
                try writer.writeAll(identifier);
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
                                try writer.writeAll(s);
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
            try printConvertedType(writer, optional.*);
            try writer.writeAll(" | null | undefined");
        },
        .template => |template| {
            if (std.mem.eql(u8, template.name, "Ref") and template.parameters != null and template.parameters.?.len == 1) {
                try writer.writeAll("import(\"fauna\").DocumentT<");
                try printConvertedType(writer, template.parameters.?[0]);
                try writer.writeByte('>');
                return;
            }

            try writer.writeAll(template.name);
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
        .string_literal => |string_literal| {
            try writer.writeAll(string_literal);
        },
        .number_literal => |number_literal| {
            try writer.writeAll(number_literal);
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
            try printConvertedType(writer, isolated.*);
            try writer.writeByte(')');
        },
    }
}

fn printTypescriptType(w: anytype, col: fauna.SchemaDefinition.Collection) !void {
    try std.fmt.format(w, "export interface {s} {{\n", .{col.name});
    if (col.members) |members| {
        for (members) |member| {
            switch (member) {
                inline .field, .computed_field => |field| {
                    try std.fmt.format(w, "    {s}: ", .{field.name});
                    if (@typeInfo(@TypeOf(field.type)) == .Optional) {
                        if (field.type) |field_type| {
                            try printConvertedType(w, field_type);
                        } else {
                            try std.fmt.format(w, "unknown", .{});
                        }
                    } else {
                        try printConvertedType(w, field.type);
                    }

                    try std.fmt.format(w, ";\n", .{});
                },
                else => {},
            }
        }
    }

    try std.fmt.format(w, "}}\n\n", .{});

    if (col.alias != null and col.alias.? == .identifier) {
        try std.fmt.format(w, "export type {s} = {s};\n\n", .{ col.alias.?.identifier, col.name });
    }
}

pub fn printTypescriptDefinitions(writer: anytype, tree: fauna.SchemaTree) !void {
    if (tree.declarations) |declarations| {
        for (declarations) |decl| {
            if (decl != .collection) {
                continue;
            }

            try printTypescriptType(writer, decl.collection);
        }
    }
}
