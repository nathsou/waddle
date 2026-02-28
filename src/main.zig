const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const wasi_host = @import("wasi_host.zig");
const parse = waddle.parse;
const runtime = waddle.runtime;
const types = waddle.types;
const wast = waddle.wast;
const Value = runtime.Value;
const Runtime = runtime.Runtime;
const Store = runtime.Store;

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
        std.debug.print("Error: missing <file.wasm/.wat/.wast> argument\n", .{});
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
    var store = runtime.Store.init(allocator, @ptrCast(&host_ctx));
    defer store.deinit();
    var converted_wasm_path: ?[]const u8 = null;
    defer if (converted_wasm_path) |p| {
        std.fs.deleteFileAbsolute(p) catch {};
        allocator.free(p);
    };

    if (std.mem.endsWith(u8, wasm_path.?, ".wat")) {
        converted_wasm_path = try wat2wasm(allocator, wasm_path.?);
    }

    if (std.mem.endsWith(u8, wasm_path.?, ".wast")) {
        try runSpecTest(allocator, wasm_path.?);
        return;
    }

    const module_path = converted_wasm_path orelse wasm_path.?;
    var vm = try Runtime.initFromFile(arena_alloc, module_path, &store, &wasi_host.WasiSnapshotPreview1.getImports());
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

fn runWasiModule(allocator: std.mem.Allocator, module_name: []const u8, host: *wasi_host.WasiSnapshotPreview1) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&path_buf);
    const tool_path = try std.fs.path.resolve(allocator, &.{ exe_dir, "..", "..", "res", "tools", module_name });
    defer allocator.free(tool_path);
    var store = runtime.Store.init(allocator, @ptrCast(host));
    var vm = try Runtime.initFromFile(allocator, tool_path, &store, &wasi_host.WasiSnapshotPreview1.getImports());
    defer vm.deinit();
    const res = try vm.invokeExportedFunc(allocator, "_start", &.{});
    allocator.free(res);
}

// use bundled `res/tools/wat2wasm.wasm` to convert the wat module to wasm
// returns the allocated path of the output .wasm file (caller must free)
fn wat2wasm(allocator: std.mem.Allocator, wat_path: []const u8) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const wat_path_resolved = try std.fs.path.resolve(allocator, &.{ cwd, wat_path });
    defer allocator.free(wat_path_resolved);
    // Generate a unique output path under the OS temp directory.
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var rand_enc: [std.fs.base64_encoder.calcSize(8)]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&rand_enc, &rand_bytes);
    const out_wasm_path = try std.fmt.allocPrint(allocator, "/tmp/waddle-{s}.wasm", .{rand_enc});
    errdefer allocator.free(out_wasm_path);
    var ctx = try wasi_host.WasiSnapshotPreview1.init(
        allocator,
        &.{ cwd, "/tmp" },
        &.{ "wat2wasm.wasm", wat_path_resolved, "-o", out_wasm_path },
        &.{},
    );
    defer ctx.deinit();
    try runWasiModule(allocator, "wat2wasm.wasm", &ctx);
    return out_wasm_path;
}

fn wast2json(allocator: std.mem.Allocator, wast_path: []const u8) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    // Generate a unique output path under the OS temp directory.
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var rand_enc: [std.fs.base64_encoder.calcSize(8)]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&rand_enc, &rand_bytes);
    const filename = std.mem.trimEnd(u8, std.fs.path.basename(wast_path), ".wast");
    const out_json_path = try std.fmt.allocPrint(allocator, "/tmp/waddle-{s}/{s}.json", .{ rand_enc, filename });
    const out_json_dir = std.fs.path.dirname(out_json_path).?;
    try std.fs.makeDirAbsolute(out_json_dir);
    errdefer allocator.free(out_json_path);
    const wast_dir = std.fs.path.dirname(wast_path).?;
    var ctx = try wasi_host.WasiSnapshotPreview1.init(
        allocator,
        &.{ cwd, wast_dir, "/tmp" },
        &.{ "wast2json.wasm", wast_path, "-o", out_json_path },
        &.{},
    );
    defer ctx.deinit();
    try runWasiModule(allocator, "wast2json.wasm", &ctx);
    return out_json_path;
}

fn runSpecTest(allocator: std.mem.Allocator, spec_test_path: []const u8) !void {
    const json_path = try wast2json(allocator, spec_test_path);
    defer allocator.free(json_path);
    const dir_path = std.fs.path.dirname(json_path).?;
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};
    const file = try std.fs.cwd().openFile(json_path, .{});
    defer file.close();
    var file_read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&file_read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(bytes);
    const parsed = try wast.parse(allocator, bytes);
    defer parsed.deinit();
    var interpreter = try wast.WastInterpreter.init(allocator, json_path);
    defer interpreter.deinit();
    try interpreter.run(parsed.value);
}
