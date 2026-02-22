const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const wasi_host = @import("wasi_host.zig");
const parse = waddle.parse;
const runtime = waddle.runtime;
const types = waddle.types;
const Value = runtime.Value;
const Runtime = runtime.Runtime;

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
    const arena_alloc = arena.allocator();
    const args = try std.process.argsAlloc(arena_alloc);

    if (args.len == 1) {
        printUsage(args[0]);
        return;
    }

    var print_bytecode = false;
    var wasm_path: ?[]const u8 = null;
    var invoke_idx: ?usize = null;
    var preopen_dirs: std.ArrayList([]const u8) = .empty;
    var vm_args: []const []const u8 = &.{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            vm_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--invoke")) {
            invoke_idx = i;
            break;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-bytecode")) {
            print_bytecode = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: missing <path> after --dir\n", .{});
                printUsage(args[0]);
                return;
            }
            try preopen_dirs.append(arena_alloc, args[i]);
        } else if (wasm_path == null) {
            wasm_path = arg;
        } else {
            std.debug.print("Error: unexpected argument: {s}\n", .{arg});
            printUsage(args[0]);
            return;
        }
    }

    if (wasm_path == null) {
        std.debug.print("Error: missing <file.wasm/.wat> argument\n", .{});
        printUsage(args[0]);
        return;
    }

    // prepend the wasm path to the vm args
    const full_vm_args = try arena_alloc.alloc([]const u8, vm_args.len + 1);
    defer arena_alloc.free(full_vm_args);
    full_vm_args[0] = wasm_path.?;
    @memcpy(full_vm_args[1..], vm_args);
    var host_ctx = try wasi_host.WasiSnapshotPreview1.init(allocator, preopen_dirs.items, full_vm_args, &.{});
    defer host_ctx.deinit();
    var vm = try createVM(arena_alloc, wasm_path.?, @ptrCast(&host_ctx));
    defer vm.deinit();
    _ = try vm.invokeStartFunc();

    if (print_bytecode) {
        var allocating_writer = std.Io.Writer.Allocating.init(arena_alloc);
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
        for (func_type.params, 0..) |param_type, j| {
            func_args[j] = try parseValue(func_arg_strings[j], param_type);
        }

        const results = try vm.invokeExportedFunc(allocator, func_name, func_args);
        defer allocator.free(results);
        for (results, 0..) |res, j| {
            std.debug.print("{f}", .{res});

            if (j != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        if (results.len > 0) {
            std.debug.print("\n", .{});
        }
    } else {
        // WASI command modules export _start as their entrypoint. Auto-invoke it
        // when no explicit --invoke flag was given, just like wasmi/wasmtime do.
        if (vm.getExportByName("_start")) |_| {
            _ = try vm.invokeExportedFunc(allocator, "_start", &.{});
        } else |err| switch (err) {
            error.ExportNotFound => {}, // not a WASI command module, nothing to do
            else => return err,
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
        "Usage: {s} [options] <file.wasm/.wat> [--invoke <func_name> [<func_args>]] [-- <vm_args>]\n" ++
            "Options:\n" ++
            "  -p, --print-bytecode   Print bytecode instructions\n" ++
            "  --dir <path>           Preopen a host directory for WASI (repeatable)\n",
        .{program_name},
    );
}

fn specTestPrintChar(vm: *Runtime) !void {
    const char_code: u8 = @intCast(try vm.stack.pop(.i32));
    _ = try std.posix.write(std.posix.STDOUT_FILENO, &.{char_code});
}

fn createVM(allocator: std.mem.Allocator, module_path: []const u8, host_ctx: ?*anyopaque) !Runtime {
    var store = runtime.Store.init(allocator, host_ctx);
    const file = try std.fs.cwd().openFile(module_path, .{});
    defer file.close();
    var file_read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&file_read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    var module: types.Module = undefined;
    var parser = parse.Parser.init(allocator, bytes);
    module = try parser.readModule();
    const imports = wasi_host.WasiSnapshotPreview1.getImports();
    const module_inst = try store.instantiate(module, &imports);
    return try Runtime.init(allocator, store, module_inst);
}
