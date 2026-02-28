const std = @import("std");
const runtime = @import("runtime.zig");

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
    type: CommandType,
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

    fn toValue(self: *Const) !runtime.Value {
        return switch (self.type) {
            .i32 => .{ .i32 = @bitCast(try std.fmt.parseInt(u32, self.value.?, 10)) },
            .i64 => .{ .i64 = @bitCast(try std.fmt.parseInt(u64, self.value.?, 10)) },
            .f32 => .{ .f32 = @floatFromInt(try std.fmt.parseInt(u32, self.value.?, 10)) },
            .f64 => .{ .f64 = @floatFromInt(try std.fmt.parseInt(u64, self.value.?, 10)) },
            .externref, .funcref => {
                return error.UnsupportedConstType;
            },
        };
    }
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

pub const WastInterpreter = struct {
    allocator: std.mem.Allocator,
    directory: []const u8,
    current_module: ?struct {
        name: ?[]const u8,
        runtime: runtime.Runtime,
        store: *runtime.Store,
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.runtime.deinit();
            self.allocator.destroy(self.store);
        }
    },

    pub fn init(allocator: std.mem.Allocator, wast_json_path: []const u8) !WastInterpreter {
        return .{
            .allocator = allocator,
            .directory = std.fs.path.dirname(wast_json_path) orelse {
                return error.InvalidPath;
            },
            .current_module = null,
        };
    }

    pub fn deinit(self: *WastInterpreter) void {
        if (self.current_module) |*mod| {
            mod.deinit();
        }
    }

    pub fn run(self: *WastInterpreter, spec: WastSpec) !void {
        for (spec.commands) |*cmd| {
            self.runCommand(cmd) catch |err| {
                std.debug.print("Error executing command {any}\n", .{cmd});
                return err;
            };
        }
    }

    fn runAction(self: *WastInterpreter, cmd: *const Command) !void {
        const action = cmd.action.?;
        switch (action.type) {
            .invoke => {
                const args = try self.allocator.alloc(runtime.Value, action.args.len);
                defer self.allocator.free(args);
                for (action.args, 0..) |*arg, i| {
                    args[i] = try arg.toValue();
                }

                if (self.current_module) |*mod| {
                    const results = try mod.runtime.invokeExportedFunc(self.allocator, action.field, args);
                    defer self.allocator.free(results);
                    if (cmd.expected.?.len != results.len) {
                        return error.ExpectedResultCountMismatch;
                    }

                    for (results, 0..) |val, i| {
                        const expected_val = try cmd.expected.?[i].toValue();
                        if (!val.eql(expected_val)) {
                            std.debug.print("Expected {any}, got {any}\n", .{ expected_val, val });
                            return error.ExpectedResultValueMismatch;
                        }
                    }
                } else {
                    return error.NoModuleLoaded;
                }
            },
            else => {
                return error.UnsupportedActionType;
            },
        }
    }

    pub fn runCommand(self: *WastInterpreter, cmd: *const Command) !void {
        switch (cmd.type) {
            .module => {
                const filename = cmd.filename.?;
                const store = try self.allocator.create(runtime.Store);
                store.* = runtime.Store.init(self.allocator, null);
                const module_path = try std.fs.path.join(self.allocator, &.{ self.directory, filename });
                defer self.allocator.free(module_path);
                const module_inst = try runtime.Runtime.initFromFile(self.allocator, module_path, store, &.{});

                if (self.current_module) |*mod| {
                    mod.deinit();
                    self.current_module = null;
                }

                self.current_module = .{
                    .name = cmd.name,
                    .runtime = module_inst,
                    .store = store,
                    .allocator = self.allocator,
                };
            },
            .assert_return => {
                try self.runAction(cmd);
            },
            .assert_trap => {
                const error_str = if (self.runAction(cmd)) |_| {
                    return error.ExpectedTrap;
                } else |err| blk: {
                    break :blk switch (err) {
                        error.IntegerDivideByZero => "integer divide by zero",
                        error.IntegerOverflow => "integer overflow",
                        else => {
                            std.debug.print("Unhandled error: {any}\n", .{err});
                            return error.UnhandledTrapError;
                        },
                    };
                };

                if (!std.mem.eql(u8, cmd.text.?, error_str)) {
                    return error.ExpectedTrapMessageMismatch;
                }
            },
            else => {},
        }
    }
};
