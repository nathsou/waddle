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

    fn isNanCanonical(self: *const Const) bool {
        if (self.value) |val| {
            return std.mem.eql(u8, val, "nan:canonical");
        }

        return false;
    }

    fn isNanArithmetic(self: *const Const) bool {
        if (self.value) |val| {
            return std.mem.eql(u8, val, "nan:arithmetic");
        }

        return false;
    }

    fn isNullRef(self: *const Const) bool {
        if (self.value) |val| {
            return (self.type == .funcref or self.type == .funcref) and std.mem.eql(u8, val, "null");
        }

        return false;
    }

    fn toValue(self: *const Const, buf: ?*usize) !runtime.Value {
        const value = self.value orelse return error.MissingConstValue;
        return switch (self.type) {
            .i32 => .{ .i32 = @bitCast(try std.fmt.parseInt(u32, value, 10)) },
            .i64 => .{ .i64 = @bitCast(try std.fmt.parseInt(u64, value, 10)) },
            .f32 => {
                if (self.isNanCanonical()) {
                    return .{ .f32 = @bitCast(@as(u32, 0x7fc00000)) };
                } else if (self.isNanArithmetic()) {
                    return .{ .f32 = @bitCast(@as(u32, 0x7fc00001)) };
                } else {
                    return .{ .f32 = @bitCast(try std.fmt.parseInt(u32, value, 10)) };
                }
            },
            .f64 => {
                if (self.isNanCanonical()) {
                    return .{ .f64 = @bitCast(@as(u64, 0x7ff8000000000000)) };
                } else if (self.isNanArithmetic()) {
                    return error.NanArithmeticNotSupported;
                } else {
                    return .{ .f64 = @bitCast(try std.fmt.parseInt(u64, value, 10)) };
                }
            },
            .externref => {
                buf.?.* = if (self.isNullRef()) runtime.Value.NullRefSentinel else try std.fmt.parseInt(usize, value, 10);
                return .{ .externref = @ptrCast(buf) };
            },
            .funcref => {
                if (self.isNullRef()) {
                    return .{ .funcref = runtime.Value.NullRefSentinel };
                } else {
                    const intval = try std.fmt.parseInt(usize, value, 10);
                    return .{ .funcref = intval };
                }
            },
        };
    }

    fn matches(self: *const Const, val: runtime.Value) !bool {
        if (self.isNanCanonical()) {
            return switch (self.type) {
                .f32 => @as(u32, @bitCast(val.f32)) & 0x7FFFFFFF == 0x7FC00000,
                .f64 => @as(u64, @bitCast(val.f64)) & 0x7FFFFFFFFFFFFFFF == 0x7FF8000000000000,
                else => return error.NanCanonicalNotSupportedForType,
            };
        }

        if (self.isNanArithmetic()) {
            return switch (self.type) {
                .f32 => @as(u32, @bitCast(val.f32)) & 0x7FC00000 == 0x7FC00000,
                .f64 => @as(u64, @bitCast(val.f64)) & 0x7FF8000000000000 == 0x7FF8000000000000,
                else => return error.NanArithmeticNotSupportedForType,
            };
        }

        if (self.value) |value| {
            if (self.type == .externref) {
                const expected_idx = try std.fmt.parseInt(usize, value, 10);
                if (val.externref) |ref_ptr| {
                    const actual_idx: usize = @as(*const usize, @ptrCast(@alignCast(ref_ptr))).*;
                    return expected_idx == actual_idx;
                }
                return false;
            }
            const expected_val = try std.fmt.parseInt(u64, value, 10);
            return expected_val == val.encode();
        }

        return switch (val.getType()) {
            .i32 => self.type == .i32,
            .i64 => self.type == .i64,
            .f32 => self.type == .f32,
            .f64 => self.type == .f64,
            .externref => self.type == .externref,
            .funcref => self.type == .funcref,
        };
    }

    pub fn format(self: *const Const, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const ty = switch (self.type) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .externref => "externref",
            .funcref => "funcref",
        };

        try writer.print("{s}", .{ty});

        if (self.value) |raw_val| {
            var buf: usize = undefined;
            if (self.toValue(&buf)) |val| {
                try writer.print("({f})", .{val});
            } else |_| {
                try writer.print("({s})", .{raw_val});
            }
        }
    }
};

pub const ActionType = enum {
    invoke,
    get,
};

pub const Action = struct {
    type: ActionType,
    module: ?[]const u8 = null,
    field: []const u8,
    args: []Const,
};

pub const ModuleType = enum {
    binary,
    text,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(WastSpec) {
    var scanner = std.json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();
    var diag = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diag);

    return std.json.parseFromTokenSource(WastSpec, allocator, &scanner, .{
        .ignore_unknown_fields = false,
    }) catch |err| {
        std.debug.print("Error parsing wast json at {d}:{d}\n", .{ diag.getLine(), diag.getColumn() });
        return err;
    };
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
            self.store.deinit();
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
        const action = cmd.action orelse return error.NullAction;
        switch (action.type) {
            .invoke => {
                const args = try self.allocator.alloc(runtime.Value, action.args.len);
                defer self.allocator.free(args);

                // buffer to hold externref values since they need to be passed as pointers
                var externref_buf: [8]usize = undefined;
                var externref_idx: usize = 0;

                for (action.args, 0..) |*arg, i| {
                    args[i] = try arg.toValue(if (arg.type == .externref) &externref_buf[externref_idx] else null);
                    if (arg.type == .externref) externref_idx += 1;
                }

                if (self.current_module) |*mod| {
                    const results = try mod.runtime.invokeExportedFunc(self.allocator, action.field, args);
                    defer self.allocator.free(results);
                    if (cmd.expected) |expected| {
                        if (expected.len != results.len) {
                            return error.ExpectedResultCountMismatch;
                        }

                        for (results, 0..) |val, i| {
                            const expected_i = &expected[i];
                            if (!(try expected_i.matches(val))) {
                                std.debug.print("Expected {f}, got {any}\n", .{ expected_i, val });
                                return error.ExpectedResultValueMismatch;
                            }
                        }
                    } else {
                        return error.MissingExpectedConstValue;
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
                const module_inst = runtime.Runtime.initFromFile(self.allocator, module_path, store, &SpecTestHost.getImports()) catch |err| {
                    std.debug.print("Error loading module from {s}: {any}\n", .{ module_path, err });
                    store.deinit();
                    self.allocator.destroy(store);
                    return err;
                };

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
                        error.InvalidIndirectCallIndex => "undefined element",
                        error.IndirectCallTypeMismatch => "indirect call type mismatch",
                        error.UninitializedTableElement => "uninitialized element",
                        error.InvalidConversionToInteger => "invalid conversion to integer",
                        error.MemoryLoadOutOfBounds, error.MemoryStoreOutOfBounds => "out of bounds memory access",
                        else => {
                            std.debug.print("Unhandled error: {any}\n", .{err});
                            return error.UnhandledTrapError;
                        },
                    };
                };

                if (cmd.text) |expected_error_str| {
                    if (!std.mem.eql(u8, expected_error_str, error_str)) {
                        std.debug.print("Expected trap message '{s}', got '{s}'\n", .{ expected_error_str, error_str });
                        return error.ExpectedTrapMessageMismatch;
                    }
                }
            },
            else => {},
        }
    }
};

const SpecTestHost = struct {
    fn printI32(vm_ptr: *anyopaque) !void {
        const vm: *runtime.Runtime = @ptrCast(@alignCast(vm_ptr));
        const val = try vm.stack.pop(.i32);
        var buf: [64]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, "{d}", .{val});
        _ = try std.posix.write(std.posix.STDOUT_FILENO, formatted);
    }

    fn getImports() [1]runtime.Store.Import {
        return .{
            .{
                .module = "spectest",
                .name = "print_i32",
                .value = .{ .func = printI32 },
            },
        };
    }
};
