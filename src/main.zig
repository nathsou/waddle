const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const runtime = waddle.runtime;
const types = waddle.types;

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

    if (args.len == 1 or args.len > 4) {
        std.debug.print(
            "Usage: {s} [options] <wasm-module> [function]\n" ++
                "Options:\n" ++
                "  -p, --print-bytecode  Print bytecode instructions\n" ++
                "  If no function is provided, invokes the start function.\n",
            .{args[0]},
        );

        return;
    }

    // Parse options
    var print_bytecode = false;
    var wasm_path_idx: ?usize = null;
    var func_name: ?[]const u8 = null;

    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-bytecode")) {
            print_bytecode = true;
        } else if (wasm_path_idx == null) {
            wasm_path_idx = idx;
        } else {
            func_name = arg;
        }
    }

    if (wasm_path_idx == null) {
        std.debug.print("Error: missing wasm-module argument\n", .{});
        return;
    }

    const wasm_path = args[wasm_path_idx.?];
    var vm = try runtime.Runtime.from(arena.allocator(), wasm_path);
    defer vm.deinit();

    if (print_bytecode) {
        var allocating_writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer allocating_writer.deinit();
        try vm.bytecode.format(&allocating_writer.writer);
        // Write accumulated buffer to stderr
        _ = try std.posix.write(std.posix.STDERR_FILENO, allocating_writer.writer.buffer);
    }

    if (func_name) |fname| {
        const results = try vm.invokeExportedFunc(fname);

        for (results, 0..) |res, i| {
            std.debug.print("{f}", .{res});

            if (i != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        std.debug.print("\n", .{});
    } else {
        try vm.invokeStartFunc();
    }
}
