const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const parse = waddle.parse;
const wat = waddle.wat;
const runtime = waddle.runtime;
const types = waddle.types;
const Value = runtime.Value;

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
        defer _ = debug_alloc.deinit();
        try run(debug_alloc.allocator());
    } else {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        try run(gpa.allocator());
    }
}

fn run(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());

    if (args.len == 1) {
        printUsage(args[0]);
        return;
    }

    var print_bytecode = false;
    var wasm_path: ?[]const u8 = null;
    var invoke_idx: ?usize = null;

    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--invoke")) {
            invoke_idx = idx;
            break;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-bytecode")) {
            print_bytecode = true;
        } else if (wasm_path == null) {
            wasm_path = arg;
        } else {
            std.debug.print(
                "Error: unexpected argument before --invoke: {s}\n",
                .{arg},
            );
            return;
        }
    }

    if (wasm_path == null) {
        std.debug.print("Error: missing <file.wasm/.wat> argument\n", .{});
        printUsage(args[0]);
        return;
    }

    var host_ctx: ?*anyopaque = null;
    var vm = try createVM(arena.allocator(), wasm_path.?, @ptrCast(&host_ctx));
    defer vm.deinit();

    _ = try vm.invokeStartFunc();

    if (print_bytecode) {
        var allocating_writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer allocating_writer.deinit();
        try vm.bytecode.format(&allocating_writer.writer);
        // Write accumulated buffer to stderr
        _ = try std.posix.write(std.posix.STDERR_FILENO, allocating_writer.writer.buffer);
    }

    if (invoke_idx) |invoke_flag_idx| {
        if (invoke_flag_idx + 1 >= args.len) {
            std.debug.print("Error: missing <func_name> after --invoke\n", .{});
            printUsage(args[0]);
            return;
        }

        const func_name = args[invoke_flag_idx + 1];
        const func_arg_strings = args[invoke_flag_idx + 2 ..];

        const func_type = try vm.getExportedFuncType(func_name);
        if (func_type.params.len != func_arg_strings.len) {
            std.debug.print(
                "Error: function '{s}' expects {d} argument(s), got {d}\n",
                .{ func_name, func_type.params.len, func_arg_strings.len },
            );
            return;
        }

        const func_args = try allocator.alloc(Value, func_type.params.len);
        defer allocator.free(func_args);
        for (func_type.params, 0..) |param_type, i| {
            func_args[i] = try parseValue(func_arg_strings[i], param_type);
        }

        const results = try vm.invokeExportedFunc(allocator, func_name, func_args);
        defer allocator.free(results);

        for (results, 0..) |res, i| {
            std.debug.print("{f}", .{res});

            if (i != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        if (results.len > 0) {
            std.debug.print("\n", .{});
        }
    }
}

fn parseValue(raw: []const u8, val_type: types.ValType) !Value {
    return switch (val_type) {
        .i32 => .{ .i32 = try std.fmt.parseInt(i32, raw, 0) },
        .i64 => .{ .i64 = try std.fmt.parseInt(i64, raw, 0) },
        .f32 => .{ .f32 = try std.fmt.parseFloat(f32, raw) },
        .f64 => .{ .f64 = try std.fmt.parseFloat(f64, raw) },
        .funcref => return error.UnsupportedFuncRefArgs,
        .externref => return error.UnsupportedExternRefArgs,
    };
}

fn printUsage(program_name: []const u8) void {
    std.debug.print(
        "Usage: {s} [options] <file.wasm/.wat> [--invoke <func_name> [<func_args>]]\n" ++
            "Options:\n" ++
            "  -p, --print-bytecode  Print bytecode instructions\n",
        .{program_name},
    );
}

fn specTestPrintChar(stack: *runtime.ValueStack, _: *runtime.ModuleInstance, _: *runtime.Store) !void {
    const char_code: u8 = @intCast(try stack.pop(.i32));
    _ = try std.posix.write(std.posix.STDOUT_FILENO, &.{char_code});
}

const WasiSnapshotPreview1Host = struct {
    const WasiErrNo = enum(u16) {
        success = 0,
        badf = 8,
    };

    fn fd_write(stack: *runtime.ValueStack, mod: *runtime.ModuleInstance, store: *runtime.Store) !void {
        const mem_inst = &store.mems.items[mod.mem_addrs[0]];
        const args = stack.staticPopValues(.i32, 4);
        const fd: u8 = @intCast(args[0]);
        const iovs_ptr: usize = @intCast(args[1]);
        const iovs_len: usize = @intCast(args[2]);
        const nwritten: usize = @intCast(args[3]);
        var total_bytes_written: usize = 0;
        const host_fd = switch (fd) {
            0 => std.posix.STDIN_FILENO,
            1 => std.posix.STDOUT_FILENO,
            2 => std.posix.STDERR_FILENO,
            else => fd,
        };

        for (0..iovs_len) |i| {
            const iov_ptr: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 0));
            const iov_len: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 4));
            const bytes = mem_inst.data[iov_ptr .. iov_ptr + iov_len];
            const bytes_written = try std.posix.write(host_fd, bytes);

            if (bytes_written != iov_len) {
                break;
            }

            total_bytes_written += bytes_written;
        }

        try mem_inst.write(.i32, nwritten, @intCast(total_bytes_written));
        try stack.push(.i32, @intCast(@intFromEnum(WasiErrNo.success)));
    }

    fn getImports() [1]runtime.Store.Import {
        return [_]runtime.Store.Import{
            .{
                .module = "wasi_snapshot_preview1",
                .name = "fd_write",
                .value = .{ .func = fd_write },
            },
        };
    }
};

fn createVM(allocator: std.mem.Allocator, module_path: []const u8, host_ctx: ?*anyopaque) !runtime.Runtime {
    var store = runtime.Store.init(allocator, host_ctx);
    const file = try std.fs.cwd().openFile(module_path, .{});
    defer file.close();
    var file_read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&file_read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    var module: types.Module = undefined;

    if (std.ascii.endsWithIgnoreCase(module_path, ".wasm")) {
        var parser = parse.Parser.init(allocator, bytes);
        module = try parser.readModule();
    } else if (std.ascii.endsWithIgnoreCase(module_path, ".wat")) {
        var parser = try wat.Parser.init(bytes, allocator);
        const wat_module = try parser.parseModule();
        module = types.Module{
            .custom = &.{},
            .types = wat_module.types,
            .imports = wat_module.imports,
            .functions = wat_module.functions,
            .tables = wat_module.tables,
            .memories = wat_module.memories,
            .globals = wat_module.globals,
            .exports = wat_module.exports,
            .start = wat_module.start,
            .elements = wat_module.elements,
            .codes = wat_module.codes,
            .data = wat_module.data,
        };
    } else {
        return error.UnsupportedModuleFormat;
    }

    const imports = WasiSnapshotPreview1Host.getImports();
    const module_inst = try store.instantiate(module, &imports);

    var start_func_addr: ?runtime.FuncAddr = null;
    if (module.start) |start_func_idx| {
        const start_func_idx_usize = @as(usize, start_func_idx);

        if (start_func_idx_usize >= module_inst.func_addrs.len) {
            return error.InvalidStartFuncIndex;
        }

        start_func_addr = module_inst.func_addrs[start_func_idx_usize];
    }

    return try runtime.Runtime.init(allocator, store, module_inst, start_func_addr);
}
