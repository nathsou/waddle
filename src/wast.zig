const std = @import("std");

// https://github.com/WebAssembly/wabt/blob/dbd22f865e46e9e7857486e7c0dfea51d997f378/docs/wast2json.md#json-format
pub const WastSpec = struct {
    source_filename: []const u8,
    commands: []Command,
};

pub const CommandType = enum {
    module,
    action,
    assert_return,
    assert_exhaustion,
    assert_trap,
    assert_invalid,
    assert_malformed,
    assert_uninstantiable,
    assert_unlinkable,
    register,
};

pub const Command = struct {
    type: []const u8,
    line: usize,

    // Optional fields because commands are polymorphic based on `type`
    filename: ?[]const u8 = null,
    action: ?Action = null,
    expected: ?[]Const = null,
    text: ?[]const u8 = null,
    module_type: ?ModuleType = null,
    name: ?[]const u8 = null,
    as: ?[]const u8 = null,
};

pub const ConstType = enum {
    i32,
    i64,
    f32,
    f64,
    externref,
    funcref,
};

pub const Const = struct {
    type: ConstType,
    value: ?[]const u8 = null,
};

pub const ActionType = enum {
    invoke,
    get,
};

pub const Action = struct {
    type: ActionType,
    field: []const u8,
    args: []Const,
};

pub const ModuleType = enum {
    binary,
    text,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(WastSpec) {
    return try std.json.parseFromSlice(WastSpec, allocator, input, .{
        .ignore_unknown_fields = false,
    });
}
